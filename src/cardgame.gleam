import gleam/bytes_builder
import gleam/dict.{type Dict}
import gleam/dynamic
import gleam/erlang/process.{type Subject}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/io
import gleam/int
import gleam/json
import gleam/option.{Some}
import gleam/otp/actor
import gleam/pair
import gleam/result
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

pub fn main() {
  // These values are for the Websocket process initialized below
  let selector = process.new_selector()
  let assert Ok(state) = actor.start(State(players: dict.new()), handle_message)

  let not_found =
    response.new(404)
    |> response.set_body(mist.Bytes(bytes_builder.new()))

  let assert Ok(_) =
    fn(req: Request(Connection)) -> Response(ResponseData) {
      case request.path_segments(req) {
        ["ws"] ->
          mist.websocket(
            request: req,
            on_init: on_init(state),
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

fn handle_ws_message(state, conn, message) {
  case message {
    mist.Text("ping") -> {
      let assert Ok(_) = mist.send_text_frame(conn, "pong")
      actor.continue(state)
    }
    mist.Text(text) -> {
      io.println("Received message: " <> text)
      actor.send(state, Incoming(text))
      actor.continue(state)
    }
    mist.Binary(_) | mist.Custom(_) -> {
      actor.continue(state)
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
      case decode_ws_message(text) {
        Error(e) -> {
          io.debug(e)
          Error(MsgTypeNotFound(e))
        }
        Ok(Chat(id, msg)) -> {
          // Send to ws if exists
          case
            dict.get(state.players, id)
            |> result.map_error(fn(_) { IdNotFound(id) })
            |> result.then(fn(player) {
              actor.send(
                player.conn_subj,
                Publish(Direct(origin_player_id, msg)),
              )
              Ok(Nil)
            })
          {
            Error(IdNotFound(id)) -> {
              dict.get(state.players, origin_player_id)
              |> result.then(fn(player) {
                actor.send(
                  player.conn_subj,
                  Publish(Err(err_to_string(IdNotFound(id)))),
                )
                Ok(Nil)
              })
              |> result.map_error(fn(_) { IdNotFound(origin_player_id) })
            }
            _ -> Ok(Nil)
          }
        }
        Ok(ChallengeRequest(id)) -> {
          case dict.get(state.players, id) {
            Ok(target_player) -> {
              // Player being challenged exists, so update the challenger to be
              // challenging them in the state.
              let state =
                dict.get(state.players, origin_player_id)
                |> result.then(fn(player) {
                  let updated_player =
                    Player(player.id, player.conn_subj, Challenging(id))
                  Ok(
                    State(players: dict.insert(
                      state.players,
                      origin_player_id,
                      updated_player,
                    )),
                  )
                })

              // Send the challenge message to the target.
              actor.send(
                target_player.conn_subj,
                Publish(Challenge(origin_player_id)),
              )

              actor.continue(state)
              Ok(Nil)
            }
            Error(_) -> {
              let _ = dict.get(state.players, origin_player_id)
              |> result.then(fn(player) {
                actor.send(
                  player.conn_subj,
                  Publish(Err(err_to_string(IdNotFound(id)))),
                )
                Ok(Nil)
              })
              Ok(Nil)
            }
          }
        }
      }
      actor.continue(state)
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
    ChallengeResponse(target, accepted) -> #(
      "challengeResponse",
      json.object([
        #("target", json.int(target)),
        #("accepted", json.bool(accepted)),
      ]),
    )
  }
  |> pair.map_first(json.string)
}

fn encode(msg: OutgoingMessage) -> String {
  let #(t, message) = msg_to_json(msg)
  json.to_string(json.object([#("type", t), #("message", message)]))
}

type IncomingMessage {
  Chat(to: Int, String)
  ChallengeRequest(target: Int)
}

type OutgoingMessage {
  Err(String)
  Direct(from: Int, String)
  Broadcast(String)
  Challenge(from: Int)
  ChallengeResponse(challenger: Int, accepted: Bool)
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
  MsgTypeNotFound(List(dynamic.DecodeError))
}

fn err_to_string(err) {
  case err {
    IdNotFound(id) -> "ID " <> int.to_string(id) <> " not found"
    _ -> "Unknown error occurred"
  }
}
