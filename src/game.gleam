import card.{type Card, Attack, Counter, Rest}
import gleam/dict.{type Dict}
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}

pub type Player(conn_subj) {
  Player(id: Int, conn_subj: conn_subj, phase: Phase)
}

pub type Phase {
  Idle
  Challenging(opponent_id: Int)
  InMatch(match_id: Int)
}

pub type State(player_conn_subj) {
  State(
    players: Dict(Int, Player(player_conn_subj)),
    matches: Dict(Int, MatchState),
  )
}

pub type Hand {
  Hand(attacks: Int, counters: Int, rests: Int)
}

pub type PlayerMatchState {
  PlayerMatchState(
    // Player ID
    id: Int,
    hand: Hand,
    chosen_card: Option(Card),
    health: Int,
    unresolved_card_choice: Option(List(Card)),
  )
}

pub type OpponentMatchState {
  OpponentMatchState(num_cards: Int, health: Int)
}

fn initial_player_state(id) {
  PlayerMatchState(
    id,
    hand: Hand(2, 1, 1),
    chosen_card: None,
    health: 5,
    unresolved_card_choice: None,
  )
}

pub type EndState {
  Draw
  Victory(winner: Int)
}

pub type PlayerIdPair {
  PlayerIdPair(Int, Int)
}

pub type MatchState {
  ResolvingRound(PlayerIdPair, List(PlayerMatchState))
  Finished(PlayerIdPair, EndState)
}

pub fn new_match(id1, id2) {
  ResolvingRound(PlayerIdPair(id1, id2), [
    initial_player_state(id1),
    initial_player_state(id2),
  ])
}

pub type RoundResult {
  MatchEnded(EndState)
  NextRound(you: PlayerMatchState, opponent: OpponentMatchState)
}

pub type GameError {
  GameError(String)
}

pub fn get_round_results(match_state: MatchState) {
  case match_state {
    Finished(PlayerIdPair(id1, id2), end_state) -> [
      #(id1, MatchEnded(end_state)),
      #(id2, MatchEnded(end_state)),
    ]
    ResolvingRound(PlayerIdPair(_, _), [player_state, opponent_state]) -> {
      [
        #(
          player_state.id,
          NextRound(
            you: player_state,
            opponent: to_opponent_state(opponent_state),
          ),
        ),
        #(
          opponent_state.id,
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

// check_no_unresolved_choices returns an error if the provided state has
// unresolved card choices.
pub fn check_no_unresolved_choices(player_state: PlayerMatchState, ok_state) {
  case player_state.unresolved_card_choice {
    None | Some([]) -> ok_state
    Some([_, ..]) ->
      Error(GameError("must pick card reward before playing next card"))
  }
}

pub fn handle_pick_card(
  match_id: Int,
  player_state: PlayerMatchState,
  choice: Card,
  opponent_state: PlayerMatchState,
) {
  case player_state.unresolved_card_choice {
    None | Some([]) -> Error(GameError("no card choices to pick"))
    Some(available_choices) -> {
      case list.contains(available_choices, choice) {
        False ->
          Error(GameError(
            card.to_string(choice) <> " is not available to choose",
          ))
        True -> {
          let player_state =
            PlayerMatchState(..player_state, unresolved_card_choice: None)
            |> add_card_to_hand(choice)

          Ok(#(
            match_id,
            ResolvingRound(PlayerIdPair(player_state.id, opponent_state.id), [
              player_state,
              opponent_state,
            ]),
          ))
        }
      }
    }
  }
}

pub fn handle_play_card(
  match_id: Int,
  player1: PlayerMatchState,
  player1_card: Card,
  player2: PlayerMatchState,
) -> Result(#(Int, MatchState), GameError) {
  let current_chosen_card = player1.chosen_card

  // Return their last played card to their hand if they had one.
  let player1 = case current_chosen_card {
    None -> player1
    Some(Attack) ->
      PlayerMatchState(
        ..player1,
        chosen_card: None,
        hand: Hand(..player1.hand, attacks: { player1.hand.attacks + 1 }),
      )
    Some(Counter) ->
      PlayerMatchState(
        ..player1,
        chosen_card: None,
        hand: Hand(..player1.hand, counters: { player1.hand.counters + 1 }),
      )
    Some(Rest) ->
      PlayerMatchState(
        ..player1,
        chosen_card: None,
        hand: Hand(..player1.hand, rests: { player1.hand.rests + 1 }),
      )
  }
  // Check they have this card in their hand and update their hand to remove
  // the card
  let player1 = case player1_card {
    Attack -> {
      let attacks = player1.hand.attacks
      case attacks > 0 {
        True ->
          PlayerMatchState(
            ..player1,
            chosen_card: Some(Attack),
            hand: Hand(..player1.hand, attacks: { attacks - 1 }),
          )
        False -> player1
      }
    }
    Counter -> {
      let counters = player1.hand.counters
      case counters > 0 {
        True -> {
          PlayerMatchState(
            ..player1,
            chosen_card: Some(Counter),
            hand: Hand(..player1.hand, counters: { counters - 1 }),
          )
        }
        False -> player1
      }
    }
    Rest -> {
      let rests = player1.hand.rests
      case rests > 0 {
        True ->
          PlayerMatchState(
            ..player1,
            chosen_card: Some(Rest),
            hand: Hand(..player1.hand, rests: { rests - 1 }),
          )
        False -> player1
      }
    }
  }
  case player1.chosen_card, player2.chosen_card {
    Some(player1_card), Some(player2_card) -> {
      let card_rewards_player1 = get_card_rewards(player1_card, player2_card)
      let card_rewards_player2 = get_card_rewards(player2_card, player1_card)

      let player1 =
        remove_current_card(player1)
        |> apply_hp_diff(get_hp_diff(player1_card, player2_card))
        |> apply_card_rewards(card_rewards_player1)

      let player2 =
        remove_current_card(player2)
        |> apply_hp_diff(get_hp_diff(player2_card, player1_card))
        |> apply_card_rewards(card_rewards_player2)

      case player1.health, player2.health {
        0, 0 ->
          Ok(#(match_id, Finished(PlayerIdPair(player1.id, player2.id), Draw)))
        0, _ ->
          Ok(#(
            match_id,
            Finished(PlayerIdPair(player1.id, player2.id), Victory(player2.id)),
          ))
        _, 0 ->
          Ok(#(
            match_id,
            Finished(PlayerIdPair(player1.id, player2.id), Victory(player1.id)),
          ))
        _, _ ->
          Ok(#(
            match_id,
            ResolvingRound(PlayerIdPair(player1.id, player2.id), [
              player1,
              player2,
            ]),
          ))
      }
    }
    None, _ -> Error(GameError("do not have card in hand"))
    Some(_), None ->
      Ok(#(
        match_id,
        ResolvingRound(PlayerIdPair(player1.id, player2.id), [player1, player2]),
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

fn apply_card_rewards(state: PlayerMatchState, choices) {
  list.fold(choices, state, fn(state, card_choice) {
    case card_choice {
      CardReward(card) -> add_card_to_hand(state, card)
      CardRewardChoice(card1, card2) ->
        PlayerMatchState(..state, unresolved_card_choice: Some([card1, card2]))
    }
  })
}

type CardReward {
  CardReward(Card)
  CardRewardChoice(a: Card, b: Card)
}

/// Returns a list of card rewards to choose from. If the length of the list is
/// less than 2 then there is no choice and you would automatically get the
/// card.
fn get_card_rewards(player_card, opponent_card) -> List(CardReward) {
  case player_card, opponent_card {
    Attack, Attack -> []
    Attack, Counter -> []
    Attack, Rest -> []
    Counter, Attack -> [CardReward(Counter)]
    Counter, Counter -> []
    Counter, Rest -> []
    Rest, Attack -> [CardReward(Attack), CardReward(Rest)]
    Rest, Counter -> [CardRewardChoice(Attack, Counter), CardReward(Rest)]
    Rest, Rest -> [CardRewardChoice(Attack, Counter), CardReward(Rest)]
  }
}

pub fn result_to_json(result: RoundResult) -> json.Json {
  case result {
    MatchEnded(Draw) -> json.object([#("resultType", json.string("draw"))])
    MatchEnded(Victory(winner)) ->
      json.object([
        #("resultType", json.string("victory")),
        #("winner", json.int(winner)),
      ])
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
            #("chosen_card", card.maybe_to_json(player.chosen_card)),
            #("health", json.int(player.health)),
            #("cardChoices", case player.unresolved_card_choice {
              Some(options) -> json.array(options, card.to_json)
              None -> json.null()
            }),
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
