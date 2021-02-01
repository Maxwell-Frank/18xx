# frozen_string_literal: true

require 'lib/params'
require 'view/link'
require 'view/game/actionable'

module View
  module Game
    class HistoryControls < Snabberb::Component
      include Actionable
      needs :num_actions, default: 0
      needs :game, store: true
      needs :round_history, default: nil, store: true

      def render
        return h(:div) if @num_actions.zero?

        divs = [h(:h3, { style: { margin: '0' } }, 'History')]
        cursor = Lib::Params['action']&.to_i

        unless cursor&.zero?
          divs << history_link('|<', 'Start', 0)

          last_round =
            if cursor == @game.raw_actions.size
              @game.round_history[-2]
            else
              @game.round_history[-1]
            end
          divs << history_link('<<', 'Previous Round', last_round, { gridColumnStart: '3' }) if last_round

          prev_action =
            if @game.exception
              @game.last_processed_action
            elsif cursor
              cursor - 1
            else
              @num_actions - 1
            end
          divs << history_link('<', 'Previous Action', prev_action, { gridColumnStart: '4' })
        end

        if cursor && !@game.exception
          divs << history_link('>', 'Next Action', cursor + 1 < @num_actions ? cursor + 1 : nil,
                               { gridColumnStart: '5' })
          store(:round_history, @game.round_history, skip: true) unless @round_history
          next_round = @round_history[@game.round_history.size]
          divs << history_link('>>', 'Next Round', next_round, { gridColumnStart: '6' }) if next_round
          divs << history_link('>|', 'Current', nil, { gridColumnStart: '7' })
        end

        props = {
          style: {
            display: 'grid',
            grid: '1fr / 4rem repeat(6, 2.5rem)',
            justifyItems: 'center',
          },
        }

        h(:div, props, divs)
      end
    end
  end
end
