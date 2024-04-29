import card.{type Card}
import game.{type Player, Challenging, Idle, InMatch}
import gleam/bytes_builder
import gleam/dict
import gleam/dynamic
import gleam/erlang/process.{type Subject}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{Some}
import gleam/otp/actor
import gleam/pair
import gleam/result
import gleam/string
import mist.{type Connection, type ResponseData}

type ConnectionMsg {
  Create(process.Subject(IndividualConnMessage))
  Delete(Int)
  Receive(from: Int, message: String)
}

type ConnectionState {
  Initialising(conn: mist.WebsocketConnection)
  Created(
    player: Player(Subject(IndividualConnMessage)),
    conn: mist.WebsocketConnection,
  )
}

type IndividualConnMessage {
  Publish(OutgoingMessage)
  CreatedPlayer(Player(Subject(IndividualConnMessage)))
  Incoming(String)
  Shutdown
}

type IncomingMessage {
  Chat(to: Int, String)
  ChallengeRequest(target: Int)
  ChallengeResponse(challenger: Int, accepted: Bool)
  PlayCard(Card)
  PickCard(Card)
}

type OutgoingMessage {
  Err(String)
  PhaseUpdate(game.Phase)
  Direct(from: Int, String)
  Broadcast(String)
  Challenge(from: Int)
  ChallengeAccepted
  RoundResult(game.RoundResult)
}

pub fn main() {
  // These values are for the Websocket process initialized below
  // let selector = process.new_selector()
  let assert Ok(state_subject) =
    actor.start(
      game.State(players: dict.new(), matches: dict.new()),
      handle_message,
    )

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
            on_close: fn(ws_conn_subject) {
              actor.send(ws_conn_subject, Shutdown)
            },
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

fn on_init(state_subj) {
  fn(conn) {
    let selector = process.new_selector()
    let assert Ok(connection_subj) =
      actor.start(Initialising(conn), fn(msg, connection_state) {
        case msg {
          CreatedPlayer(player) -> {
            io.println(
              "Player " <> int.to_string(player.id) <> " has connected.",
            )
            actor.continue(Created(player, conn))
          }
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
          Shutdown -> {
            case connection_state {
              Created(player, _) -> {
                io.println(
                  "Player " <> int.to_string(player.id) <> " has disconnected.",
                )
              }
              _ -> Nil
            }
            actor.Stop(process.Normal)
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
  state: game.State(Subject(IndividualConnMessage)),
) -> actor.Next(ConnectionMsg, game.State(Subject(IndividualConnMessage))) {
  case msg {
    Create(conn_subj) -> {
      let id = dict.size(state.players)
      let player = game.Player(id, conn_subj, Idle)
      actor.send(conn_subj, CreatedPlayer(player))
      let new_state =
        game.State(..state, players: dict.insert(state.players, id, player))
      actor.continue(new_state)
    }
    Delete(id) ->
      game.State(..state, players: dict.delete(state.players, id))
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

fn handle_message_from_client(
  state: game.State(Subject(IndividualConnMessage)),
  origin_player: Player(Subject(IndividualConnMessage)),
  text: String,
) {
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
                game.State(
                  ..state,
                  players: dict.insert(
                    state.players,
                    origin_player.id,
                    game.Player(..origin_player, phase: next_phase),
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
            game.State(
              players: dict.insert(
                state.players,
                challenger.id,
                game.Player(..challenger, phase: InMatch(match_id)),
              )
                |> dict.insert(
                origin_player.id,
                game.Player(..origin_player, phase: InMatch(match_id)),
              ),
              matches: dict.insert(
                state.matches,
                match_id,
                game.new_match(origin_player.id, challenger.id),
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
            game.State(
              ..state,
              players: dict.insert(
                state.players,
                challenger.id,
                game.Player(..challenger, phase: Idle),
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
            Ok(game.Finished(_, _)) ->
              Error(InvalidRequest("match has concluded"))
            Ok(game.ResolvingRound(_, [player1, player2]))
              | Ok(game.ResolvingRound(_, [player2, player1])) if player1.id
              == origin_player.id ->
              game.check_no_unresolved_choices(
                player1,
                game.handle_play_card(match_id, player1, card, player2),
              )
              |> result.map_error(convert_to_ws_error)
            Ok(game.ResolvingRound(_, _)) ->
              Error(InvalidRequest("bad match state"))
            Error(_) -> Error(InvalidRequest("match not found"))
          }
        }
        _ -> Error(InvalidRequest("cannot play card: not in match"))
      }
      case match_state {
        Ok(match_state) -> {
          let #(match_id, new_match_state) = match_state

          let _ = case game.get_round_results(new_match_state) {
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

          let players = case new_match_state {
            game.Finished(game.PlayerIdPair(id1, id2), _) -> {
              let player1 = dict.get(state.players, id1)
              let player2 = dict.get(state.players, id2)
              case player1, player2 {
                Ok(player1), Ok(player2) ->
                  state.players
                  |> dict.insert(id1, game.Player(..player1, phase: Idle))
                  |> dict.insert(id2, game.Player(..player2, phase: Idle))
                _, _ -> state.players
              }
            }
            _ -> state.players
          }

          actor.continue(game.State(
            players: players,
            matches: dict.insert(state.matches, match_id, new_match_state),
          ))
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
    Ok(PickCard(choice)) -> {
      let match_state = case origin_player.phase {
        InMatch(match_id) -> {
          let match_state = dict.get(state.matches, match_id)
          case match_state {
            Ok(game.Finished(_, _)) ->
              Error(InvalidRequest("match has concluded"))
            Ok(game.ResolvingRound(_, [player, opponent]))
              | Ok(game.ResolvingRound(_, [opponent, player])) if player.id
              == origin_player.id ->
              game.handle_pick_card(match_id, player, choice, opponent)
              |> result.map_error(convert_to_ws_error)
            Ok(game.ResolvingRound(_, _)) ->
              Error(InvalidRequest("bad match state"))
            Error(_) -> Error(InvalidRequest("match not found"))
          }
        }
        _ -> Error(InvalidRequest("cannot play card: not in match"))
      }
      case match_state {
        Ok(match_state) -> {
          let #(match_id, new_match_state) = match_state

          let _ = case game.get_round_results(new_match_state) {
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

          let players = case new_match_state {
            game.Finished(game.PlayerIdPair(id1, id2), _) -> {
              let player1 = dict.get(state.players, id1)
              let player2 = dict.get(state.players, id2)
              case player1, player2 {
                Ok(player1), Ok(player2) ->
                  state.players
                  |> dict.insert(id1, game.Player(..player1, phase: Idle))
                  |> dict.insert(id2, game.Player(..player2, phase: Idle))
                _, _ -> state.players
              }
            }
            _ -> state.players
          }

          actor.continue(game.State(
            players: players,
            matches: dict.insert(state.matches, match_id, new_match_state),
          ))
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
    RoundResult(result) -> #("result", game.result_to_json(result))
  }
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
      |> dynamic.decode1(PlayCard, dynamic.field("card", card.decode_json))
    Ok(#("pickCard", msg)) ->
      msg
      |> dynamic.decode1(PickCard, dynamic.field("card", card.decode_json))

    Ok(#(found, _)) ->
      Error([
        dynamic.DecodeError(
          "chat | challenge | challengeResponse | playCard | pickCard",
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

fn convert_to_ws_error(game_error) {
  let game.GameError(reason) = game_error
  InvalidRequest(reason)
}
