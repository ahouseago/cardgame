import gleam/bytes_builder
import gleam/dict.{type Dict}
import gleam/dynamic
import gleam/erlang/process.{type Subject}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/pair
import gleam/result
import gleam/string
import mist.{type Connection, type ResponseData}

type Phase {
  Idle
  Challenging(opponent_id: Int)
  InMatch(match_id: Int)
}

type Player {
  Player(id: Int, conn_subj: Subject(IndividualConnMessage), phase: Phase)
}

type IndividualConnMessage {
  Publish(OutgoingMessage)
  CreatedPlayer(Player)
  Incoming(String)
}

type State {
  State(players: Dict(Int, Player), matches: Dict(Int, MatchState))
}

type ConnectionMsg {
  Create(process.Subject(IndividualConnMessage))
  Delete(Int)
  Receive(from: Int, message: String)
}

type Card {
  Attack
  Counter
  Rest
}

type Hand {
  Hand(attacks: Int, counters: Int, rests: Int)
}

type PlayerMatchState {
  PlayerMatchState(
    cards_remaining: Hand,
    chosen_card: option.Option(Card),
    health: Int,
  )
}

fn initial_match_state() {
  PlayerMatchState(cards_remaining: Hand(2, 1, 1), chosen_card: None, health: 5)
}

type MatchState {
  ResolvingRound(List(#(Int, PlayerMatchState)))
  Finished(winner: Int, loser: Int)
}

type IncomingMessage {
  Chat(to: Int, String)
  ChallengeRequest(target: Int)
  ChallengeResponse(challenger: Int, accepted: Bool)
  PlayCard(Card)
}

type OutgoingMessage {
  Err(String)
  PhaseUpdate(Phase)
  Direct(from: Int, String)
  Broadcast(String)
  Challenge(from: Int)
  ChallengeAccepted
  CardsRemaining(Hand)
}

pub fn main() {
  // These values are for the Websocket process initialized below
  // let selector = process.new_selector()
  let assert Ok(state_subject) =
    actor.start(State(players: dict.new(), matches: dict.new()), handle_message)

  let not_found =
    response.new(404)
    |> response.set_body(mist.Bytes(bytes_builder.new()))

  let assert Ok(_) =
    fn(req: Request(Connection)) -> Response(ResponseData) {
      case request.path_segments(req) {
        ["ws"] ->
          mist.websocket(
            request: req,
            on_init: on_init(state_subject),
            on_close: fn(_state) { io.println("goodbye!") },
            handler: handle_ws_message,
          )

        _ -> not_found
      }
    }
    |> mist.new
    |> mist.port(3000)
    |> mist.start_http

  process.sleep_forever()
}

type ConnectionState {
  Initialising(conn: mist.WebsocketConnection)
  Created(player: Player, conn: mist.WebsocketConnection)
}

fn on_init(state_subj) {
  fn(conn) {
    let selector = process.new_selector()
    let assert Ok(connection_subj) =
      actor.start(Initialising(conn), fn(msg, connection_state) {
        case msg {
          CreatedPlayer(player) -> actor.continue(Created(player, conn))
          Incoming(text) -> {
            case connection_state {
              Created(player, _) -> {
                actor.send(state_subj, Receive(player.id, text))
                actor.continue(connection_state)
              }
              _ -> actor.continue(connection_state)
            }
          }
          Publish(outgoing_message) -> {
            let assert Ok(_) =
              mist.send_text_frame(conn, encode(outgoing_message))
            actor.continue(connection_state)
          }
        }
      })

    actor.send(state_subj, Create(connection_subj))

    #(connection_subj, Some(selector))
  }
}

fn handle_ws_message(ws_conn_subject, conn, message) {
  case message {
    mist.Text("ping") -> {
      let assert Ok(_) = mist.send_text_frame(conn, "pong")
      actor.continue(ws_conn_subject)
    }
    mist.Text(text) -> {
      io.println("Received message: " <> text)
      actor.send(ws_conn_subject, Incoming(text))
      actor.continue(ws_conn_subject)
    }
    mist.Binary(_) | mist.Custom(_) -> {
      actor.continue(ws_conn_subject)
    }
    mist.Closed | mist.Shutdown -> actor.Stop(process.Normal)
  }
}

fn handle_message(
  msg: ConnectionMsg,
  state: State,
) -> actor.Next(ConnectionMsg, State) {
  case msg {
    Create(conn_subj) -> {
      let id = dict.size(state.players)
      let player = Player(id, conn_subj, Idle)
      actor.send(conn_subj, CreatedPlayer(player))
      let new_state =
        State(..state, players: dict.insert(state.players, id, player))
      actor.continue(new_state)
    }
    Delete(id) ->
      State(..state, players: dict.delete(state.players, id))
      |> actor.continue
    Receive(origin_player_id, text) -> {
      case dict.get(state.players, origin_player_id) {
        Ok(origin_player) ->
          handle_message_from_client(state, origin_player, text)
        Error(_) -> {
          io.println(
            "Recieved message from player with ID "
            <> int.to_string(origin_player_id)
            <> " not found in state.",
          )
          actor.continue(state)
        }
      }
    }
  }
}

fn handle_message_from_client(state: State, origin_player: Player, text: String) {
  case decode_ws_message(text) {
    Error(e) -> {
      io.debug(e)
      actor.send(
        origin_player.conn_subj,
        Publish(Err(err_to_string(MsgTypeNotFound(e)))),
      )
      actor.continue(state)
    }
    Ok(Chat(id, msg)) -> {
      // Send to ws if exists
      case dict.get(state.players, id) {
        Ok(player) ->
          actor.send(player.conn_subj, Publish(Direct(origin_player.id, msg)))
        Error(_) ->
          actor.send(
            origin_player.conn_subj,
            Publish(Err(err_to_string(IdNotFound(id)))),
          )
      }
      actor.continue(state)
    }
    Ok(ChallengeRequest(id)) -> {
      case origin_player.phase {
        InMatch(_) | Challenging(_) -> {
          actor.send(
            origin_player.conn_subj,
            Publish(
              Err(
                err_to_string(InvalidRequest(
                  "Cannot challenge while already challenging a player",
                )),
              ),
            ),
          )
          actor.continue(state)
        }
        Idle ->
          case dict.get(state.players, id) {
            Ok(target_player) -> {
              // Player being challenged exists, so update the challenger to be
              // challenging them in the state.
              let next_phase = Challenging(id)
              let new_state =
                State(
                  ..state,
                  players: dict.insert(
                    state.players,
                    origin_player.id,
                    Player(..origin_player, phase: next_phase),
                  ),
                )
              actor.send(
                origin_player.conn_subj,
                Publish(PhaseUpdate(next_phase)),
              )

              // Send the challenge message to the target.
              actor.send(
                target_player.conn_subj,
                Publish(Challenge(origin_player.id)),
              )

              actor.continue(new_state)
            }
            Error(_) -> {
              actor.send(
                origin_player.conn_subj,
                Publish(Err(err_to_string(IdNotFound(id)))),
              )
              actor.continue(state)
            }
          }
      }
    }
    Ok(ChallengeResponse(challenger_id, accepted)) -> {
      let challenger =
        dict.get(state.players, challenger_id)
        |> result.replace_error(IdNotFound(challenger_id))
        |> result.then(fn(challenger) {
          case challenger.phase {
            Challenging(target) if target == origin_player.id -> Ok(challenger)
            _ -> {
              let err =
                InvalidRequest(
                  "Could not respond to challenge: player is not challenging you.",
                )
              actor.send(
                origin_player.conn_subj,
                Publish(Err(err_to_string(err))),
              )
              Error(err)
            }
          }
        })
      case challenger, accepted {
        Ok(challenger), True -> {
          let match_id = dict.size(state.matches)
          let new_state =
            State(
              players: dict.insert(
                  state.players,
                  challenger.id,
                  Player(..challenger, phase: InMatch(match_id)),
                )
                |> dict.insert(
                  origin_player.id,
                  Player(..origin_player, phase: InMatch(match_id)),
                ),
              matches: dict.insert(
                state.matches,
                match_id,
                ResolvingRound([
                  #(origin_player.id, initial_match_state()),
                  #(challenger.id, initial_match_state()),
                ]),
              ),
            )
          io.println(
            "match started: "
            <> int.to_string(match_id)
            <> "players: "
            <> list.map([origin_player.id, challenger.id], int.to_string)
            |> string.join(", "),
          )

          actor.send(challenger.conn_subj, Publish(ChallengeAccepted))
          actor.send(
            origin_player.conn_subj,
            Publish(PhaseUpdate(InMatch(challenger.id))),
          )
          actor.send(
            challenger.conn_subj,
            Publish(PhaseUpdate(InMatch(origin_player.id))),
          )

          actor.continue(new_state)
        }
        Ok(challenger), False -> {
          let new_state =
            State(
              ..state,
              players: dict.insert(
                state.players,
                challenger.id,
                Player(..challenger, phase: Idle),
              ),
            )
          actor.send(challenger.conn_subj, Publish(PhaseUpdate(Idle)))
          io.println(
            "challenge refused, [target, challenger] = "
            <> list.map([origin_player.id, challenger.id], int.to_string)
            |> string.join(", "),
          )

          actor.continue(new_state)
        }
        Error(ws_err), _ -> {
          actor.send(
            origin_player.conn_subj,
            Publish(Err(err_to_string(ws_err))),
          )
          actor.continue(state)
        }
      }
    }
    Ok(PlayCard(card)) -> {
      let match_state = case origin_player.phase {
        InMatch(match_id) -> {
          let match_state = dict.get(state.matches, match_id)
          case match_state {
            Ok(Finished(_, _)) -> Error(InvalidRequest("match has concluded"))
            Ok(ResolvingRound([
                #(player1_id, player1_state),
                #(player2_id, player2_state),
              ])) if player1_id == origin_player.id ->
              handle_play_card(
                match_id,
                player1_id,
                player1_state,
                card,
                player2_id,
                player2_state,
              )
            Ok(ResolvingRound([
                #(player2_id, player2_state),
                #(player1_id, player1_state),
              ])) if player1_id == origin_player.id ->
              handle_play_card(
                match_id,
                player1_id,
                player1_state,
                card,
                player2_id,
                player2_state,
              )
            Ok(ResolvingRound(_)) -> Error(InvalidRequest("bad match state"))
            Error(_) -> Error(InvalidRequest("match not found"))
          }
        }
        _ -> Error(InvalidRequest("cannot play card: not in match"))
      }
      case match_state {
        Ok(match_state) -> {
          let #(match_id, new_match_state) = match_state
          actor.continue(
            State(
              ..state,
              matches: dict.insert(state.matches, match_id, new_match_state),
            ),
          )
        }
        Error(ws_err) -> {
          actor.send(
            origin_player.conn_subj,
            Publish(Err(err_to_string(ws_err))),
          )
          actor.continue(state)
        }
      }
    }
  }
}

fn handle_play_card(
  match_id: Int,
  player1_id: Int,
  player1_state: PlayerMatchState,
  player1_card: Card,
  player2_id: Int,
  player2_state: PlayerMatchState,
) -> Result(#(Int, MatchState), WsMsgError) {
  let current_chosen_card = player1_state.chosen_card
  let player1_state = case current_chosen_card {
    None -> player1_state
    Some(Attack) ->
      PlayerMatchState(
        ..player1_state,
        chosen_card: None,
        cards_remaining: Hand(
          ..player1_state.cards_remaining,
          attacks: { player1_state.cards_remaining.attacks + 1 },
        ),
      )
    Some(Counter) ->
      PlayerMatchState(
        ..player1_state,
        chosen_card: None,
        cards_remaining: Hand(
          ..player1_state.cards_remaining,
          counters: { player1_state.cards_remaining.counters + 1 },
        ),
      )
    Some(Rest) ->
      PlayerMatchState(
        ..player1_state,
        chosen_card: None,
        cards_remaining: Hand(
          ..player1_state.cards_remaining,
          rests: { player1_state.cards_remaining.rests + 1 },
        ),
      )
  }
  // Check they have this card in their hand and update their hand to remove
  // the card
  let player1_state = case player1_card {
    Attack -> {
      let attacks = player1_state.cards_remaining.attacks
      case attacks > 0 {
        True ->
          PlayerMatchState(
            ..player1_state,
            chosen_card: Some(Attack),
            cards_remaining: Hand(
              ..player1_state.cards_remaining,
              attacks: { attacks - 1 },
            ),
          )
        False -> player1_state
      }
    }
    Counter -> {
      let counters = player1_state.cards_remaining.counters
      case counters > 0 {
        True -> {
          PlayerMatchState(
            ..player1_state,
            chosen_card: Some(Counter),
            cards_remaining: Hand(
              ..player1_state.cards_remaining,
              counters: { counters - 1 },
            ),
          )
        }
        False -> player1_state
      }
    }
    Rest -> {
      let rests = player1_state.cards_remaining.rests
      case rests > 0 {
        True ->
          PlayerMatchState(
            ..player1_state,
            chosen_card: Some(Rest),
            cards_remaining: Hand(
              ..player1_state.cards_remaining,
              rests: { rests - 1 },
            ),
          )
        False -> player1_state
      }
    }
  }
  case player1_state.chosen_card, player2_state.chosen_card {
    Some(player1_card), Some(player2_card) -> todo as "resolve the round"
    None, _ -> Error(InvalidRequest("do not have card in hand"))
    Some(_), None ->
      Ok(#(
        match_id,
        ResolvingRound([
          #(player1_id, player1_state),
          #(player2_id, player2_state),
        ]),
      ))
  }
}

fn msg_to_json(msg) {
  case msg {
    Err(text) -> #("error", json.string(text))
    Direct(from, text) -> #(
      "chat",
      json.object([#("from", json.int(from)), #("text", json.string(text))]),
    )
    Broadcast(text) -> #("broadcast", json.string(text))
    Challenge(from) -> #("challenge", json.object([#("from", json.int(from))]))
    ChallengeAccepted -> #("challengeAccepted", json.null())
    PhaseUpdate(phase) -> #(
      "status",
      json.object([
        #(
          "phase",
          case phase {
              Idle -> "idle"
              Challenging(id) ->
                "waiting for challenge response from " <> int.to_string(id)
              InMatch(id) -> "in a match with " <> int.to_string(id)
            }
            |> json.string,
        ),
      ]),
    )
    CardsRemaining(hand) -> #(
      "cards",
      json.object([
        #("attacks", json.int(hand.attacks)),
        #("counters", json.int(hand.counters)),
        #("rests", json.int(hand.rests)),
      ]),
    )
  }
  // ChallengeResponse(target, accepted) -> #(
  //   "challengeResponse",
  //   json.object([
  //     #("target", json.int(target)),
  //     #("accepted", json.bool(accepted)),
  //   ]),
  // )
  |> pair.map_first(json.string)
}

fn encode(msg: OutgoingMessage) -> String {
  let #(t, message) = msg_to_json(msg)
  json.to_string(json.object([#("type", t), #("message", message)]))
}

// {
//   "type": "chat",
//   "message": {
//     "to": 2,
//     "text": "abc"
//   }
// }

fn decode_ws_message(
  text: String,
) -> Result(IncomingMessage, List(dynamic.DecodeError)) {
  let type_decoder =
    dynamic.decode2(
      fn(t, msg) { #(t, msg) },
      dynamic.field("type", dynamic.string),
      dynamic.field("message", dynamic.dynamic),
    )
  let msg_with_type = json.decode(text, type_decoder)
  case msg_with_type {
    Ok(#("chat", msg)) ->
      msg
      |> dynamic.decode2(
        Chat,
        dynamic.field("to", dynamic.int),
        dynamic.field("text", dynamic.string),
      )
    Ok(#("challenge", msg)) ->
      msg
      |> dynamic.decode1(ChallengeRequest, dynamic.field("target", dynamic.int))
    Ok(#("challengeResponse", msg)) ->
      msg
      |> dynamic.decode2(
        ChallengeResponse,
        dynamic.field("challenger", dynamic.int),
        dynamic.field("accepted", dynamic.bool),
      )
    Ok(#("playCard", msg)) ->
      msg
      |> dynamic.decode1(
        PlayCard,
        dynamic.field("card", fn(card) {
          dynamic.string(card)
          |> result.then(fn(card_str) {
            case card_str {
              "attack" -> Ok(Attack)
              "counter" -> Ok(Counter)
              "rest" -> Ok(Rest)
              other ->
                Error([
                  dynamic.DecodeError("attack | counter | rest", other, [
                    "message", "card",
                  ]),
                ])
            }
          })
        }),
      )
    Ok(#(found, _)) ->
      Error([
        dynamic.DecodeError(
          "chat | challenge | challengeResponse | playCard",
          found,
          [],
        ),
      ])
    Error(json.UnexpectedFormat(e)) -> Error(e)
    Error(json.UnexpectedByte(byte, _))
    | Error(json.UnexpectedSequence(byte, _)) ->
      Error([dynamic.DecodeError(byte, "", [])])
    Error(_) -> Error([dynamic.DecodeError("chat or broadcast", "", [])])
  }
}

type WsMsgError {
  IdNotFound(Int)
  InvalidRequest(reason: String)
  MsgTypeNotFound(List(dynamic.DecodeError))
}

fn err_to_string(err) {
  case err {
    IdNotFound(id) -> "ID " <> int.to_string(id) <> " not found"
    InvalidRequest(reason) -> "Invalid request: " <> reason
    _ -> "Unknown error occurred"
  }
}
