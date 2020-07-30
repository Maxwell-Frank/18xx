# frozen_string_literal: true

if RUBY_ENGINE == 'opal'
  require_tree 'part'
else
  require 'require_all'
  require_rel 'part'
end

require_relative 'game_error'
require_relative 'config/tile'

module Engine
  class Tile
    include Config::Tile

    attr_accessor :hex, :icons, :index, :legal_rotations, :location_name, :name, :reservations
    attr_reader :blocks_lay, :borders, :cities, :color, :edges, :junction, :label, :nodes,
                :parts, :preprinted, :rotation, :stops, :towns, :upgrades, :offboards, :blockers

    ALL_EDGES = [0, 1, 2, 3, 4, 5].freeze

    def self.for(name, **opts)
      if (code = WHITE[name])
        color = :white
      elsif (code = YELLOW[name])
        color = :yellow
      elsif (code = GREEN[name])
        color = :green
      elsif (code = BROWN[name])
        color = :brown
      elsif (code = GRAY[name])
        color = :gray
      elsif (code = RED[name])
        color = :red
      elsif (code = BLUE[name])
        color = :blue
      else
        raise Engine::GameError, "Tile '#{name}' not found"
      end

      from_code(name, color, code, **opts)
    end

    def self.decode(code)
      cache = []

      code.split(';').map do |part_code|
        type, params = part_code.split('=')
        params ||= ''

        params = params.split(',').map { |param| param.split(':') }.to_h if params.include?(':')

        part(type, params, cache)
      end
    end

    def self.from_code(name, color, code, **opts)
      Tile.new(name, color: color, parts: decode(code), **opts)
    end

    def self.part(type, params, cache)
      case type
      when 'path'
        params = params.map do |k, v|
          case v[0]
          when '_'
            [k, cache[v[1..-1].to_i]]
          else
            [k, Part::Edge.new(v)]
          end
        end.to_h

        Part::Path.new(params['a'], params['b'])
      when 'city'
        city = Part::City.new(params['revenue'],
                              slots: params['slots'],
                              groups: params['groups'],
                              hide: params['hide'],
                              visit_cost: params['visit_cost'],
                              route: params['route'],
                              format: params['format'])
        cache << city
        city
      when 'town'
        town = Part::Town.new(params['revenue'],
                              groups: params['groups'],
                              hide: params['hide'],
                              visit_cost: params['visit_cost'],
                              route: params['route'],
                              format: params['format'])
        cache << town
        town
      when 'offboard'
        offboard = Part::Offboard.new(params['revenue'],
                                      groups: params['groups'],
                                      hide: params['hide'],
                                      visit_cost: params['visit_cost'],
                                      route: params['route'],
                                      format: params['format'])
        cache << offboard
        offboard
      when 'label'
        label = Part::Label.new(params)
        cache << label
        label
      when 'upgrade'
        upgrade = Part::Upgrade.new(params['cost'], params['terrain']&.split('|'))
        cache << upgrade
        upgrade
      when 'border'
        Part::Border.new(params['edge'], params['type'], params['cost'])
      when 'junction'
        junction = Part::Junction.new
        cache << junction
        junction
      when 'icon'
        Part::Icon.new(params['image'], params['name'], params['sticky'], params['blocks_lay'])
      end
    end

    # rotation 0-5
    def initialize(name,
                   color:,
                   parts:,
                   rotation: 0,
                   preprinted: false,
                   index: 0,
                   location_name: nil,
                   **opts)
      @name = name
      @color = color.to_sym
      @parts = parts
      @rotation = rotation
      @cities = []
      @paths = []
      @towns = []
      @upgrades = []
      @offboards = []
      @original_borders = []
      @borders = []
      @branches = nil
      @nodes = nil
      @stops = nil
      @edges = nil
      @junction = nil
      @icons = []
      @location_name = location_name
      @legal_rotations = []
      @blockers = []
      @reservations = []
      @preprinted = preprinted
      @index = index
      @blocks_lay = nil
      @reservation_blocks = opts[:reservation_blocks] || false

      separate_parts
    end

    def id
      "#{@name}-#{@index}"
    end

    def <=>(other)
      [COLORS.index(@color), @name.to_i] <=> [COLORS.index(other.color), other.name.to_i]
    end

    def rotate!(absolute = nil)
      new_rotation = absolute ||
        @legal_rotations.find { |r| r > @rotation } ||
        @legal_rotations.first ||
        @rotation
      @rotation = new_rotation
      @nodes.each(&:clear!)
      @_paths = nil
      @_exits = nil
      @preferred_city_town_edges = nil
      self
    end

    def rotate(num, ticks = 1)
      (num + ticks) % 6
    end

    def paths
      @_paths ||= @paths.map { |path| path.rotate(@rotation) }
    end

    def exits
      @_exits ||= @edges.map { |e| rotate(e.num, @rotation) }.uniq
    end

    def lawson?
      @lawson ||=
        !!@junction ||
        (@cities.one? && @towns.empty?) ||
        ((cities.empty? && towns.one?) && edges.size > 2)
    end

    def terrain
      @upgrades.flat_map(&:terrains).uniq
    end

    def upgrades_to?(other, special_lay = false)
      # correct color progression?
      return false unless COLORS.index(other.color) == (COLORS.index(@color) + 1)

      # honors pre-existing track?
      return false unless paths_are_subset_of?(other.paths)

      # If special ability then remaining checks is not applicable
      return true if special_lay

      # correct label?
      return false if label != other.label

      # honors existing town/city counts?
      # - allow labelled cities to upgrade regardless of count; they're probably
      #   fine (e.g., 18Chesapeake's OO cities merge to one city in brown)
      # - TODO: account for games that allow double dits to upgrade to one town
      return false if @towns.size != other.towns.size
      return false if !label && @cities.size != other.cities.size

      true
    end

    def paths_are_subset_of?(other_paths)
      ALL_EDGES.any? do |ticks|
        @paths.all? do |path|
          path = path.rotate(ticks)
          other_paths.any? { |other| path <= other }
        end
      end
    end

    def add_blocker!(private_company)
      @parts << private_company
      @blockers << private_company
    end

    def inspect
      "<#{self.class.name}: #{name}, hex: #{@hex&.name}>"
    end

    # returns hash where keys are cities, and values are the edge the city or
    # town should be rendered at
    #
    # "ct" for "city or town"
    def preferred_city_town_edges
      @preferred_city_town_edges ||= compute_city_town_edges
    end

    def reserved_by?(corporation)
      @reservations.any? { |r| [r, r.owner].include?(corporation) }
    end

    def add_reservation!(entity, city, slot = 0)
      # Single city, assume the first
      city = 0 if @cities.one?

      if city
        @cities[city].add_reservation!(entity, slot)
      else
        @reservations << entity
      end
    end

    def token_blocked_by_reservation?(corporation)
      return false if @reservations.empty?

      if @reservation_blocks
        !@reservations.include?(corporation)
      else
        @reservations.count { |x| corporation != x } >= @cities.sum(&:available_slots)
      end
    end

    def city_town_edges
      # Returns a list of each edge a city/town goes to
      ct_edges = Hash.new { |h, k| h[k] = [] }
      paths.each do |path|
        next unless (ct = path.city || path.town)

        path.exits.each do |edge|
          ct_edges[ct] << edge
        end
      end
      ct_edges.values
    end

    def compute_city_town_edges
      # ct => nums of edges it is connected to
      ct_edges = Hash.new { |h, k| h[k] = [] }

      # edge => how many tracks/cts are on that edge, plus 0.1
      # for each track/ct on neighboring edges
      edge_count = Hash.new(0)

      if @paths.empty? && @cities.size >= 2
        # If a tile has no paths but multiple cities, avoid them rendering on top of each other
        div = 6 / @cities.size
        @cities.each_with_index { |x, index| edge_count[x] = (index * div) }
        return edge_count
      end

      # slightly prefer to keep room along bottom to render location name
      edge_count[0] += 0.1

      # populate ct_edges and edge_count as described in above comments
      paths.each do |path|
        next unless (ct = path.city || path.town)

        path.exits.each do |edge|
          ct_edges[ct] << edge
          edge_count[edge] += 1
          edge_count[(edge + 1) % 6] += 0.1
          edge_count[(edge - 1) % 6] += 0.1
        end
      end

      # sort ct_edges so that the lowest edge with any paths will be
      # handled first
      ct_edges = ct_edges.each { |_, e| e.sort! }.sort_by { |_, e| e }

      # construct the final hash to return, updating edge_count along the
      # way
      ct_edges = ct_edges.map do |ct, edges_|
        edge = edges_.min_by { |e| edge_count[e] }

        # since this edge is being used, increase its count (and that of its
        # neighbors) to influence what edges will be used for the remaining
        # cts
        edge_count[edge] += 1
        edge_count[(edge + 1) % 6] += 0.1
        edge_count[(edge - 1) % 6] += 0.1

        [ct, edge]
      end.to_h

      city_towns = @cities + @towns
      pathless_cts = city_towns.select { |ct| ct.paths.empty? }
      if pathless_cts.one? && city_towns.size == 2
        ct = pathless_cts.first
        ct_edges[ct] = (ct_edges.values.first + 3) % 6
      end

      ct_edges
    end

    def revenue_to_render
      @revenue_to_render ||= stops.map(&:revenue_to_render)
    end

    # Used to set label for a recently placed tile
    def label=(label_name)
      @label = Part::Label.new(label_name)
    end

    def restore_borders(edges = nil)
      edges ||= ALL_EDGES

      # Re-add borders that are in the edge list returning those that are missing
      edges.map do |edge|
        original = @original_borders.find { |e| e.edge == edge }
        next unless original
        next if @borders.include?(original)

        @borders << original
        edge
      end.compact
    end

    private

    def separate_parts
      @parts.each do |part|
        @blocks_lay ||= part.blocks_lay?

        if part.city?
          @cities << part
        elsif part.label?
          @label = part
        elsif part.path?
          @paths << part
        elsif part.town?
          @towns << part
        elsif part.upgrade?
          @upgrades << part
        elsif part.offboard?
          @offboards << part
        elsif part.border?
          @original_borders << part
          @borders << part
        elsif part.junction?
          @junction = part
        elsif part.icon?
          @icons << part
        else
          raise "Part #{part} not separated."
        end
      end

      @parts.each.group_by(&:class).values.each do |parts|
        parts.each.with_index do |part, index|
          part.index = index
          part.tile = self
        end
      end

      @nodes = @paths.map(&:node).compact.uniq
      @branches = @paths.map(&:branch).compact.uniq
      @stops = @paths.map(&:stop).compact.uniq
      @edges = @paths.flat_map(&:edges).compact.uniq
    end
  end
end
