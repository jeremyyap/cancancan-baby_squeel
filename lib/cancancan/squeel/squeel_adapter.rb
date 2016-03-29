class CanCanCan::Squeel::SqueelAdapter < CanCan::ModelAdapters::AbstractAdapter
  include CanCanCan::Squeel::AttributeMapper

  def self.for_class?(model_class)
    model_class <= ActiveRecord::Base
  end

  def self.override_condition_matching?(subject, name, _)
    return false unless subject.class.respond_to?(:defined_enums)

    subject.class.defined_enums.include?(name.to_s)
  end

  def self.matches_condition?(subject, name, value)
    # Get the mapping from enum strings to values.
    enum = subject.class.public_send(name.to_s.pluralize)

    # Get the value of the attribute as an integer.
    attribute = enum[subject.public_send(name)]

    # Check to see if the value matches the condition.
    value.is_a?(Enumerable) ? value.include?(attribute) : attribute == value
  end

  def database_records
    # TODO: Handle overridden scopes.
    relation.distinct
  end

  private

  # Builds a relation that expresses the set of provided rules.
  #
  # This first joins all the tables specified in the rules, then builds the corresponding Squeel
  # expression for the conditions.
  def relation
    join_scope = @rules.reduce(@model_class.where(nil)) do |scope, rule|
      add_joins_to_scope(scope, build_join_list(rule.conditions))
    end

    add_conditions_to_scope(join_scope)
  end

  # Builds an array of joins for the given conditions hash.
  #
  # For example:
  #
  # a: { b: { c: 3 }, d: { e: 4 }} => [[:a, :b], [:a, :d]]
  #
  # @param [Hash] conditions The conditions to build the joins.
  # @return [Array<Array<Symbol>>] The joins needed to satisfy the given conditions
  def build_join_list(conditions)
    conditions.flat_map do |key, value|
      if value.is_a?(Hash)
        [[key]].concat(build_join_list(value).map { |join| Array(join).unshift(key) })
      else
        []
      end
    end
  end

  # Builds a relation, outer joined on the provided associations.
  #
  # @param [ActiveRecord::Relation] scope The current scope to add the joins to.
  # @param [Array<Array<Symbol>>] joins The set of associations to outer join with.
  # @return [ActiveRecord::Relation] The built relation.
  def add_joins_to_scope(scope, joins)
    joins.reduce(scope) do |result, join|
      result.joins do
        join.reduce(self) do |relation, association|
          relation.__send__(association).outer
        end
      end
    end
  end

  # Adds the rule conditions to the scope.
  #
  # This builds Squeel expression for each rule, and combines the expression with those to the left
  # using a fold-left.
  #
  # @param [ActiveRecord::Relation] scope The scope to add the rule conditions to.
  def add_conditions_to_scope(scope)
    adapter = self
    rules = @rules

    # default n
    scope.where do
      rules.reduce(nil) do |left_expression, rule|
        combined_rule = adapter.send(:combine_expression_with_rule, self, left_expression, rule)
        break if combined_rule.nil?

        combined_rule
      end
    end
  end

  # Combines the given expression with the new rule.
  #
  # @param squeel The Squeel scope.
  # @param left_expression The Squeel expression for all preceding rules.
  # @param [CanCan::Rule] rule The rule being added.
  # @return [Squeel::Nodes::Node] If the rule has an expression.
  # @return [NilClass] If the rule is unconditional.
  def combine_expression_with_rule(squeel, left_expression, rule)
    right_expression = build_expression_from_rule(squeel, rule)
    return right_expression if right_expression.nil? || !left_expression

    if rule.base_behavior
      left_expression | right_expression
    else
      left_expression & right_expression
    end
  end

  # Builds a Squeel expression representing the rule's conditions.
  #
  # @param squeel The Squeel scope.
  # @param [CanCan::Rule] rule The rule being built.
  def build_expression_from_rule(squeel, rule)
    comparator = rule.base_behavior ? :== : :!=
    build_expression_node(squeel, @model_class, comparator, rule.conditions, true)
  end

  # Builds a new Squeel expression node.
  #
  # @param node The parent node context.
  # @param [Class] model_class The model class which the conditions reference.
  # @param [Symbol] comparator The comparator to use when generating the comparison.
  # @param [Hash] conditions The values to compare the given node's attributes against.
  # @param [Boolean] root True if the node being built is from the root. The root node is special
  #   because it does not mutate itself; all other nodes do.
  def build_expression_node(node, model_class, comparator, conditions, root = false)
    conditions.reduce(nil) do |left_expression, (key, value)|
      comparison_node = build_comparison_node(root ? node : node.dup, model_class, key,
                                              comparator, value)
      if left_expression
        left_expression & comparison_node
      else
        comparison_node
      end
    end
  end

  # Builds a comparison node for the given key and value.
  #
  # @param node The node context to build the comparison.
  # @param [Class] model_class The model class which the conditions reference.
  # @param [Symbol] key The column to compare against.
  # @param [Symbol] comparator The comparator to compare the column against the value.
  # @param value The value to compare the column against.
  def build_comparison_node(node, model_class, key, comparator, value)
    if value.is_a?(Hash)
      reflection = model_class.reflect_on_association(key)
      build_expression_node(node.__send__(key), reflection.klass, comparator, value)
    else
      key, comparator, value = squeel_comparison_for(model_class, key, comparator, value)
      node.__send__(key).public_send(comparator, value)
    end
  end
end
