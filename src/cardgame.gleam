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
import gleam/option.{Some}
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
  State(players: Dict(Int, Player))
}

type ConnectionMsg {
  Create(process.Subject(IndividualConnMessage))
  Delete(Int)
  Receive(from: Int, message: String)
}

type IncomingMessage {
  Chat(to: Int, String)
  ChallengeRequest(target: Int)
  ChallengeResponse(challenger: Int, accepted: Bool)
}

type OutgoingMessage {
  Err(String)
  Direct(from: Int, String)
  Broadcast(String)
  Challenge(from: Int)
  ChallengeAccepted
}

pub fn main() {
  // These values are for the Websocket process initialized below
  // let selector = process.new_selector()
  let assert Ok(state_subject) =
    actor.start(State(players: dict.new()), handle_message)

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
      let new_state = State(players: dict.insert(state.players, id, player))
      actor.continue(new_state)
    }
    Delete(id) ->
      State(players: dict.delete(state.players, id))
      |> actor.continue
    Receive(origin_player_id, text) -> {
      let origin_player = dict.get(state.players, origin_player_id)

      case origin_player, decode_ws_message(text) {
        Ok(origin_player), Error(e) -> {
          io.debug(e)
          actor.send(
            origin_player.conn_subj,
            Publish(Err(err_to_string(MsgTypeNotFound(e)))),
          )
          actor.continue(state)
        }
        Ok(origin_player), Ok(Chat(id, msg)) -> {
          // Send to ws if exists
          case dict.get(state.players, id) {
            Ok(player) ->
              actor.send(
                player.conn_subj,
                Publish(Direct(origin_player_id, msg)),
              )
            Error(_) ->
              actor.send(
                origin_player.conn_subj,
                Publish(Err(err_to_string(IdNotFound(id)))),
              )
          }
          actor.continue(state)
        }
        Ok(origin_player), Ok(ChallengeRequest(id)) -> {
          case dict.get(state.players, id) {
            Ok(target_player) -> {
              // Player being challenged exists, so update the challenger to be
              // challenging them in the state.
              let new_state =
                State(players: dict.insert(
                  state.players,
                  origin_player_id,
                  Player(..origin_player, phase: Challenging(id)),
                ))

              // Send the challenge message to the target.
              actor.send(
                target_player.conn_subj,
                Publish(Challenge(origin_player_id)),
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
        Ok(origin_player), Ok(ChallengeResponse(challenger_id, accepted)) -> {
          let challenger =
            dict.get(state.players, challenger_id)
            |> result.replace_error(IdNotFound(challenger_id))
            |> result.then(fn(challenger) {
              case challenger.phase {
                Challenging(target) if target == origin_player_id ->
                  Ok(challenger)
                _ -> {
                  let err =
                    InvalidRequest(
                      "Could not accept challenge: player is not challenging you.",
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
              let new_state =
                State(
                  players: dict.insert(
                    state.players,
                    challenger.id,
                    Player(..challenger, phase: InMatch(origin_player_id)),
                  )
                  |> dict.insert(
                    origin_player_id,
                    Player(..origin_player, phase: InMatch(challenger.id)),
                  ),
                )
              io.println(
                "players now in a match: "
                <> list.map([origin_player_id, challenger.id], int.to_string)
                |> string.join(", "),
              )

              actor.send(challenger.conn_subj, Publish(ChallengeAccepted))

              actor.continue(new_state)
            }
            Ok(challenger), False -> {
              let new_state =
                State(players: dict.insert(
                  state.players,
                  challenger.id,
                  Player(..challenger, phase: Idle),
                ))
              io.println(
                "challenge refused, [target, challenger] = "
                <> list.map([origin_player_id, challenger.id], int.to_string)
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
        Error(_), _ -> {
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
    Ok(#(found, _)) ->
      Error([dynamic.DecodeError("chat or challenge", found, [])])
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
