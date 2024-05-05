import game.{type Player}
import gleam/bytes_builder
import gleam/dict
import gleam/erlang/process.{type Subject}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import messaging.{
  Challenge, ChallengeAccepted, ChallengeRequest, ChallengeResponse, Chat,
  Connected, Direct, Err, PhaseUpdate, PickCard, PlayCard, RoundResult,
}
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
  Publish(messaging.OutgoingMessage)
  CreatedPlayer(Player(Subject(IndividualConnMessage)))
  Incoming(String)
  Shutdown
}

pub fn main() {
  // These values are for the Websocket process initialized below
  // let selector = process.new_selector()
  let assert Ok(state_subject) =
    actor.start(
      game.State(next_id: 0, players: dict.new(), matches: dict.new()),
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
              mist.send_text_frame(conn, messaging.encode(outgoing_message))
            actor.continue(connection_state)
          }
          Shutdown -> {
            case connection_state {
              Created(player, _) -> {
                actor.send(state_subj, Delete(player.id))
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

fn get_next_id(state: game.State(a)) {
  let id = state.next_id
  #(game.State(..state, next_id: id + 1), id)
}

fn handle_message(
  msg: ConnectionMsg,
  state: game.State(Subject(IndividualConnMessage)),
) -> actor.Next(ConnectionMsg, game.State(Subject(IndividualConnMessage))) {
  case msg {
    Create(conn_subj) -> {
      let #(state, id) = get_next_id(state)
      let player = game.Player(id, conn_subj, messaging.Idle)
      actor.send(conn_subj, CreatedPlayer(player))
      actor.send(conn_subj, Publish(Connected(id)))
      let state =
        game.State(..state, players: dict.insert(state.players, id, player))
      actor.continue(state)
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
  case messaging.decode_ws_message(text) {
    Error(e) -> {
      io.debug(e)
      actor.send(
        origin_player.conn_subj,
        Publish(Err(messaging.err_to_string(messaging.MsgTypeNotFound(e)))),
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
            Publish(Err(messaging.err_to_string(messaging.IdNotFound(id)))),
          )
      }
      actor.continue(state)
    }
    Ok(ChallengeRequest(id)) -> {
      case origin_player.phase {
        messaging.InMatch(_) | messaging.Challenging(_) -> {
          actor.send(
            origin_player.conn_subj,
            Publish(
              Err(
                messaging.err_to_string(messaging.InvalidRequest(
                  "Cannot challenge while already challenging a player",
                )),
              ),
            ),
          )
          actor.continue(state)
        }
        messaging.Idle ->
          case dict.get(state.players, id) {
            Ok(target_player) -> {
              // Player being challenged exists, so update the challenger to be
              // challenging them in the state.
              let next_phase = messaging.Challenging(id)
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
                Publish(Err(messaging.err_to_string(messaging.IdNotFound(id)))),
              )
              actor.continue(state)
            }
          }
      }
    }
    Ok(ChallengeResponse(challenger_id, accepted)) -> {
      let challenger =
        dict.get(state.players, challenger_id)
        |> result.replace_error(messaging.IdNotFound(challenger_id))
        |> result.then(fn(challenger) {
          case challenger.phase {
            messaging.Challenging(target) if target == origin_player.id ->
              Ok(challenger)
            _ -> {
              let err =
                messaging.InvalidRequest(
                  "Could not respond to challenge: player is not challenging you.",
                )
              actor.send(
                origin_player.conn_subj,
                Publish(Err(messaging.err_to_string(err))),
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
              ..state,
              players: dict.insert(
                  state.players,
                  challenger.id,
                  game.Player(..challenger, phase: messaging.InMatch(match_id)),
                )
                |> dict.insert(
                  origin_player.id,
                  game.Player(
                    ..origin_player,
                    phase: messaging.InMatch(match_id),
                  ),
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
            Publish(PhaseUpdate(messaging.InMatch(challenger.id))),
          )
          actor.send(
            challenger.conn_subj,
            Publish(PhaseUpdate(messaging.InMatch(origin_player.id))),
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
                game.Player(..challenger, phase: messaging.Idle),
              ),
            )
          actor.send(challenger.conn_subj, Publish(PhaseUpdate(messaging.Idle)))
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
            Publish(Err(messaging.err_to_string(ws_err))),
          )
          actor.continue(state)
        }
      }
    }
    Ok(PlayCard(card)) -> {
      let match_state = case origin_player.phase {
        messaging.InMatch(match_id) -> {
          let match_state = dict.get(state.matches, match_id)
          case match_state {
            Ok(messaging.Finished(_, _)) ->
              Error(messaging.InvalidRequest("match has concluded"))
            Ok(messaging.ResolvingRound(_, [player1, player2]))
              | Ok(messaging.ResolvingRound(_, [player2, player1])) if player1.id
              == origin_player.id ->
              game.check_no_unresolved_choices(
                player1,
                game.handle_play_card(match_id, player1, card, player2),
              )
              |> result.map_error(game.convert_to_ws_error)
            Ok(messaging.ResolvingRound(_, _)) ->
              Error(messaging.InvalidRequest("bad match state"))
            Error(_) -> Error(messaging.InvalidRequest("match not found"))
          }
        }
        _ -> Error(messaging.InvalidRequest("cannot play card: not in match"))
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
                  actor.send(
                    player.conn_subj,
                    Publish(messaging.RoundResult(result1)),
                  )
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
            messaging.Finished(messaging.PlayerIdPair(id1, id2), _) -> {
              let player1 = dict.get(state.players, id1)
              let player2 = dict.get(state.players, id2)
              case player1, player2 {
                Ok(player1), Ok(player2) ->
                  state.players
                  |> dict.insert(
                    id1,
                    game.Player(..player1, phase: messaging.Idle),
                  )
                  |> dict.insert(
                    id2,
                    game.Player(..player2, phase: messaging.Idle),
                  )
                _, _ -> state.players
              }
            }
            _ -> state.players
          }

          actor.continue(
            game.State(
              ..state,
              players: players,
              matches: dict.insert(state.matches, match_id, new_match_state),
            ),
          )
        }
        Error(ws_err) -> {
          actor.send(
            origin_player.conn_subj,
            Publish(Err(messaging.err_to_string(ws_err))),
          )
          actor.continue(state)
        }
      }
    }
    Ok(PickCard(choice)) -> {
      let match_state = case origin_player.phase {
        messaging.InMatch(match_id) -> {
          let match_state = dict.get(state.matches, match_id)
          case match_state {
            Ok(messaging.Finished(_, _)) ->
              Error(messaging.InvalidRequest("match has concluded"))
            Ok(messaging.ResolvingRound(_, [player, opponent]))
              | Ok(messaging.ResolvingRound(_, [opponent, player])) if player.id
              == origin_player.id ->
              game.handle_pick_card(match_id, player, choice, opponent)
              |> result.map_error(game.convert_to_ws_error)
            Ok(messaging.ResolvingRound(_, _)) ->
              Error(messaging.InvalidRequest("bad match state"))
            Error(_) -> Error(messaging.InvalidRequest("match not found"))
          }
        }
        _ -> Error(messaging.InvalidRequest("cannot play card: not in match"))
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
            messaging.Finished(messaging.PlayerIdPair(id1, id2), _) -> {
              let player1 = dict.get(state.players, id1)
              let player2 = dict.get(state.players, id2)
              case player1, player2 {
                Ok(player1), Ok(player2) ->
                  state.players
                  |> dict.insert(
                    id1,
                    game.Player(..player1, phase: messaging.Idle),
                  )
                  |> dict.insert(
                    id2,
                    game.Player(..player2, phase: messaging.Idle),
                  )
                _, _ -> state.players
              }
            }
            _ -> state.players
          }

          actor.continue(
            game.State(
              ..state,
              players: players,
              matches: dict.insert(state.matches, match_id, new_match_state),
            ),
          )
        }
        Error(ws_err) -> {
          actor.send(
            origin_player.conn_subj,
            Publish(Err(messaging.err_to_string(ws_err))),
          )
          actor.continue(state)
        }
      }
    }
  }
}
