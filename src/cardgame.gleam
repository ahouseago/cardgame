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
import gleam/option.{type Option, None, Some}
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
  PlayerMatchState(hand: Hand, chosen_card: option.Option(Card), health: Int)
}

type OpponentMatchState {
  OpponentMatchState(num_cards: Int, health: Int)
}

fn initial_match_state() {
  PlayerMatchState(hand: Hand(2, 1, 1), chosen_card: None, health: 5)
}

type EndState {
  Draw
  Victory(winner: Int)
}

type PlayerIdPair {
  PlayerIdPair(Int, Int)
}

type MatchState {
  ResolvingRound(PlayerIdPair, List(#(Int, PlayerMatchState)))
  Finished(PlayerIdPair, EndState)
}

type RoundResult {
  MatchEnded(EndState)
  ChooseCard(List(Card))
  NextRound(you: PlayerMatchState, opponent: OpponentMatchState)
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
  RoundResult(RoundResult)
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
                ResolvingRound(PlayerIdPair(origin_player.id, challenger.id), [
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
            Ok(ResolvingRound(
                _,
                [#(player1_id, player1_state), #(player2_id, player2_state)],
              )) if player1_id == origin_player.id ->
              handle_play_card(
                match_id,
                player1_id,
                player1_state,
                card,
                player2_id,
                player2_state,
              )
            Ok(ResolvingRound(
                _,
                [#(player2_id, player2_state), #(player1_id, player1_state)],
              )) if player1_id == origin_player.id ->
              handle_play_card(
                match_id,
                player1_id,
                player1_state,
                card,
                player2_id,
                player2_state,
              )
            Ok(ResolvingRound(_, _)) -> Error(InvalidRequest("bad match state"))
            Error(_) -> Error(InvalidRequest("match not found"))
          }
        }
        _ -> Error(InvalidRequest("cannot play card: not in match"))
      }
      case match_state {
        Ok(match_state) -> {
          let #(match_id, new_match_state) = match_state

          case get_round_results(new_match_state) {
            [#(id1, result1), #(id2, result2)] -> {
              let _ =
                state.players
                |> dict.get(id1)
                |> result.then(fn(player) {
                  actor.send(player.conn_subj, Publish(RoundResult(result1)))
                  Ok(Nil)
                })
              let _ =
                state.players
                |> dict.get(id2)
                |> result.then(fn(player) {
                  actor.send(player.conn_subj, Publish(RoundResult(result2)))
                  Ok(Nil)
                })
              Ok(Nil)
            }
            _ -> Error(Nil)
          }

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

fn get_round_results(match_state: MatchState) {
  case match_state {
    Finished(PlayerIdPair(id1, id2), end_state) -> [
      #(id1, MatchEnded(end_state)),
      #(id2, MatchEnded(end_state)),
    ]
    ResolvingRound(
      PlayerIdPair(_, _),
      [#(id, player_state), #(opponent_id, opponent_state)],
    ) -> {
      [
        #(
          id,
          NextRound(
            you: player_state,
            opponent: to_opponent_state(opponent_state),
          ),
        ),
        #(
          opponent_id,
          NextRound(
            you: opponent_state,
            opponent: to_opponent_state(player_state),
          ),
        ),
      ]
    }
    ResolvingRound(PlayerIdPair(id1, id2), _) -> [
      #(id1, MatchEnded(Draw)),
      #(id2, MatchEnded(Draw)),
    ]
  }
}

fn to_opponent_state(state: PlayerMatchState) -> OpponentMatchState {
  let num_cards = state.hand.attacks + state.hand.counters + state.hand.rests
  OpponentMatchState(num_cards: num_cards, health: state.health)
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

  // Return their last played card to their hand if they had one.
  let player1_state = case current_chosen_card {
    None -> player1_state
    Some(Attack) ->
      PlayerMatchState(
        ..player1_state,
        chosen_card: None,
        hand: Hand(
          ..player1_state.hand,
          attacks: { player1_state.hand.attacks + 1 },
        ),
      )
    Some(Counter) ->
      PlayerMatchState(
        ..player1_state,
        chosen_card: None,
        hand: Hand(
          ..player1_state.hand,
          counters: { player1_state.hand.counters + 1 },
        ),
      )
    Some(Rest) ->
      PlayerMatchState(
        ..player1_state,
        chosen_card: None,
        hand: Hand(
          ..player1_state.hand,
          rests: { player1_state.hand.rests + 1 },
        ),
      )
  }
  // Check they have this card in their hand and update their hand to remove
  // the card
  let player1_state = case player1_card {
    Attack -> {
      let attacks = player1_state.hand.attacks
      case attacks > 0 {
        True ->
          PlayerMatchState(
            ..player1_state,
            chosen_card: Some(Attack),
            hand: Hand(..player1_state.hand, attacks: { attacks - 1 }),
          )
        False -> player1_state
      }
    }
    Counter -> {
      let counters = player1_state.hand.counters
      case counters > 0 {
        True -> {
          PlayerMatchState(
            ..player1_state,
            chosen_card: Some(Counter),
            hand: Hand(..player1_state.hand, counters: { counters - 1 }),
          )
        }
        False -> player1_state
      }
    }
    Rest -> {
      let rests = player1_state.hand.rests
      case rests > 0 {
        True ->
          PlayerMatchState(
            ..player1_state,
            chosen_card: Some(Rest),
            hand: Hand(..player1_state.hand, rests: { rests - 1 }),
          )
        False -> player1_state
      }
    }
  }
  case player1_state.chosen_card, player2_state.chosen_card {
    Some(player1_card), Some(player2_card) -> {
      let card_rewards_player1 = get_card_rewards(player1_card, player2_card)
      let card_rewards_player2 = get_card_rewards(player2_card, player1_card)
      // for now just add all the new cards, need to add an intermediate state
      // where the players are choosing their reward later to limit it to 1
      // each round.
      let player1_state =
        remove_current_card(player1_state)
        |> apply_hp_diff(get_hp_diff(player1_card, player2_card))
        |> list.fold(card_rewards_player1, _, add_card_to_hand)

      let player2_state =
        remove_current_card(player2_state)
        |> apply_hp_diff(get_hp_diff(player2_card, player1_card))
        |> list.fold(card_rewards_player2, _, add_card_to_hand)

      case player1_state.health, player2_state.health {
        0, 0 ->
          Ok(#(match_id, Finished(PlayerIdPair(player1_id, player2_id), Draw)))
        0, _ ->
          Ok(#(
            match_id,
            Finished(PlayerIdPair(player1_id, player2_id), Victory(player2_id)),
          ))
        _, 0 ->
          Ok(#(
            match_id,
            Finished(PlayerIdPair(player1_id, player2_id), Victory(player1_id)),
          ))
        _, _ ->
          Ok(#(
            match_id,
            ResolvingRound(PlayerIdPair(player1_id, player2_id), [
              #(player1_id, player1_state),
              #(player2_id, player2_state),
            ]),
          ))
      }
    }
    None, _ -> Error(InvalidRequest("do not have card in hand"))
    Some(_), None ->
      Ok(#(
        match_id,
        ResolvingRound(PlayerIdPair(player1_id, player2_id), [
          #(player1_id, player1_state),
          #(player2_id, player2_state),
        ]),
      ))
  }
}

fn add_card_to_hand(state, card) {
  case card {
    Attack ->
      PlayerMatchState(
        ..state,
        hand: Hand(..state.hand, attacks: { state.hand.attacks + 1 }),
      )
    Counter ->
      PlayerMatchState(
        ..state,
        hand: Hand(..state.hand, counters: { state.hand.counters + 1 }),
      )
    Rest ->
      PlayerMatchState(
        ..state,
        hand: Hand(..state.hand, rests: { state.hand.rests + 1 }),
      )
  }
}

// fn resolve_round(
//   player1_state: PlayerMatchState,
//   player1_card: Card,
//   player2_state: PlayerMatchState,
//   player2_card: Card,
// ) {
//   let card_rewards_player1 = get_card_rewards(player1_card, player2_card)
//   let card_rewards_player2 = get_card_rewards(player2_card, player1_card)
//   let player1_state =
//     apply_hp_diff(player1_state, get_hp_diff(player1_card, player2_card))
//   let player2_state =
//     apply_hp_diff(player2_state, get_hp_diff(player2_card, player1_card))
//
//   #(#(card_rewards_player1, player1_state), #(
//     card_rewards_player2,
//     player2_state,
//   ))
// }

fn get_hp_diff(player_card, opponent_card) {
  // Could "simplify" this into two cases: one that returns -1 and one that
  // returns 0 but this is probably more readable and easier to tweak later.
  case player_card, opponent_card {
    Attack, Attack -> -1
    Attack, Counter -> -1
    Attack, Rest -> 0
    Counter, Attack -> 0
    Counter, Counter -> 0
    Counter, Rest -> 0
    Rest, Attack -> -1
    Rest, Counter -> 0
    Rest, Rest -> 0
  }
}

fn apply_hp_diff(state, diff) {
  PlayerMatchState(..state, health: state.health + diff)
}

fn remove_current_card(state) {
  PlayerMatchState(..state, chosen_card: None)
}

/// Returns a list of card rewards to choose from. If the length of the list is
/// less than 2 then there is no choice and you would automatically get the
/// card.
fn get_card_rewards(player_card, opponent_card) {
  case player_card, opponent_card {
    Attack, Attack -> []
    Attack, Counter -> []
    Attack, Rest -> []
    Counter, Attack -> [Counter]
    Counter, Counter -> []
    Counter, Rest -> []
    Rest, Attack -> [Attack, Rest]
    Rest, Counter -> [Attack, Counter, Rest]
    Rest, Rest -> [Attack, Counter, Rest]
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
    RoundResult(result) -> #("result", result_to_json(result))
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

fn result_to_json(result: RoundResult) -> json.Json {
  case result {
    MatchEnded(Draw) -> json.object([#("resultType", json.string("draw"))])
    MatchEnded(Victory(winner)) ->
      json.object([
        #("resultType", json.string("victory")),
        #("winner", json.int(winner)),
      ])
    ChooseCard(_) -> todo
    NextRound(player, opponent) ->
      json.object([
        #(
          "player",
          json.object([
            #(
              "hand",
              json.object([
                #("attacks", json.int(player.hand.attacks)),
                #("counters", json.int(player.hand.counters)),
                #("rests", json.int(player.hand.rests)),
              ]),
            ),
            #("chosen_card", card_to_json(player.chosen_card)),
            #("health", json.int(player.health)),
          ]),
        ),
        #(
          "opponent",
          json.object([
            #("cardCount", json.int(opponent.num_cards)),
            #("health", json.int(opponent.health)),
          ]),
        ),
      ])
  }
}

fn card_to_json(card: Option(Card)) -> json.Json {
  case card {
    Some(Attack) -> json.string("attack")
    Some(Counter) -> json.string("counter")
    Some(Rest) -> json.string("rest")
    None -> json.null()
  }
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
