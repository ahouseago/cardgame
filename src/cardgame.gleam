import gleam/bytes_builder
import gleam/dict.{type Dict}
import gleam/dynamic
import gleam/erlang/process
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/io
import gleam/int
import gleam/json
import gleam/list
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
  Player(id: Int, conn: mist.WebsocketConnection, phase: Phase)
}

type State {
  State(players: Dict(Int, Player))
}

type ConnectionMsg {
  Create(mist.WebsocketConnection)
  Delete(Int)
  Receive(from: mist.WebsocketConnection, message: String)
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
            on_init: on_init(state, selector),
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

fn on_init(state_subj, selector) {
  fn(conn) {
    actor.send(state_subj, Create(conn))
    #(state_subj, Some(selector))
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
      actor.send(state, Receive(conn, text))
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
    Create(conn) -> {
      let id = dict.size(state.players)
      let new_state =
        State(players: dict.insert(state.players, id, new_player(id, conn)))
      actor.continue(new_state)
    }
    Delete(id) ->
      State(players: dict.delete(state.players, id))
      |> actor.continue
    Receive(origin_conn, text) -> {
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
              mist.send_text_frame(player.conn, msg)
              |> result.map_error(fn(_) { WebsocketConnErr })
            })
          {
            Error(IdNotFound(id)) -> {
              send_error(origin_conn, IdNotFound(id))
            }
            _ -> Ok(Nil)
          }
        }
        Ok(ChallengeRequest(id)) -> {
          case dict.get(state.players, id) {
            Ok(target_player) -> {
              // don't think I have the origin player here to update their
              // state to challenging
              mist.send_text_frame(
                target_player.conn,
                "Challenged to a match by X, do you accept?",
              )
              |> result.map_error(fn(_) { WebsocketConnErr })
            }
            Error(_) -> send_error(origin_conn, IdNotFound(id))
          }
        }
      }
      actor.continue(state)
    }
  }
}

fn new_player(id, conn) -> Player {
  Player(id, conn, Idle)
}

fn msg_to_json(msg) {
  case msg {
    Err(text) -> #("error", json.string(text))
    Direct(to, text) -> #(
      "chat",
      json.object([#("to", json.int(to)), #("text", json.string(text))]),
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
    Ok(#("challengeRequest", msg)) ->
      msg
      |> dynamic.decode1(ChallengeRequest, dynamic.field("target", dynamic.int))
    Ok(#(found, _)) ->
      Error([dynamic.DecodeError("chat or broadcast", found, [])])
    Error(json.UnexpectedFormat(e)) -> Error(e)
    Error(json.UnexpectedByte(byte, _))
    | Error(json.UnexpectedSequence(byte, _)) ->
      Error([dynamic.DecodeError(byte, "", [])])
    Error(_) -> Error([dynamic.DecodeError("chat or broadcast", "", [])])
  }
}

type WsMsgError {
  IdNotFound(Int)
  // Could use `glisten.SocketReason` to distinguish more about this error if needed.
  WebsocketConnErr
  MsgTypeNotFound(List(dynamic.DecodeError))
}

fn send_error(conn, err) {
  case err {
    IdNotFound(id) ->
      mist.send_text_frame(conn, "ID " <> int.to_string(id) <> " not found")
    _ -> mist.send_text_frame(conn, "Unknown error occurred")
  }
  |> result.map_error(fn(_) { WebsocketConnErr })
}
