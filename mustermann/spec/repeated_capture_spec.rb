# frozen_string_literal: true
require 'support'
require 'mustermann'
require 'mustermann/set'

describe 'repeated_capture: :equal' do
  subject(:pattern) { Mustermann.new('/:tenant/projects/:tenant', repeated_capture: :equal) }

  context 'matching' do
    it 'matches when both captures decode to the same value' do
      pattern.params('/acme/projects/acme').should be == { 'tenant' => 'acme' }
    end

    it 'compares values after URI decoding, so different legal encodings of the same value match' do
      pattern.params('/abc/projects/%61bc').should be == { 'tenant' => 'abc' }
      pattern.params('/%61%62%63/projects/abc').should be == { 'tenant' => 'abc' }
      pattern.params('/a%20b/projects/a%20b').should be == { 'tenant' => 'a b' }
      pattern.params('/a~b/projects/a%7Eb').should be == { 'tenant' => 'a~b' }
    end

    it 'does not match when the decoded values differ' do
      pattern.params('/a/projects/b').should be_nil
      pattern.match('/a/projects/b').should be_nil
      pattern.should_not be === '/a/projects/b'
      (pattern =~ '/a/projects/b').should be_nil
    end

    it 'returns the single shared value, not an array' do
      pattern.params('/acme/projects/acme').should be == { 'tenant' => 'acme' }
    end

    it 'supports peeking' do
      pattern.peek_params('/acme/projects/acme/rest').should be == [{ 'tenant' => 'acme' }, 19]
      pattern.peek_params('/a/projects/b/rest').should be_nil
      pattern.peek_size('/acme/projects/acme/rest').should be == 19
      pattern.peek_size('/a/projects/b/rest').should be_nil
    end

    it 'works with other AST pattern types' do
      rails = Mustermann.new('/:tenant/projects/:tenant', type: :rails, repeated_capture: :equal)
      rails.params('/acme/projects/%61cme').should be == { 'tenant' => 'acme' }
      rails.params('/a/projects/b').should be_nil
    end

    it 'supports more than two occurrences' do
      pattern = Mustermann.new('/:a/:a/:a', repeated_capture: :equal)
      pattern.params('/x/x/x').should be == { 'a' => 'x' }
      pattern.params('/x/x/y').should be_nil
    end

    it 'supports mixing repeated and normal captures' do
      pattern = Mustermann.new('/:tenant/:project/:tenant', repeated_capture: :equal)
      pattern.params('/a/b/%61').should be == { 'tenant' => 'a', 'project' => 'b' }
      pattern.params('/a/b/c').should be_nil
    end

    it 'works inside union patterns' do
      pattern = Mustermann.new('/:a/x/:a', repeated_capture: :equal) | Mustermann.new('/static')
      pattern.params('/foo/x/foo').should be == { 'a' => 'foo' }
      pattern.params('/foo/x/bar').should be_nil
      pattern.params('/static').should be == {}
    end
  end

  context 'with optional branches' do
    subject(:pattern) { Mustermann.new('/:tenant(/projects/:tenant)?', repeated_capture: :equal) }

    it 'does not constrain captures whose optional branch did not participate' do
      pattern.params('/acme').should be == { 'tenant' => 'acme' }
    end

    it 'constrains captures when the optional branch participates' do
      pattern.params('/acme/projects/%61cme').should be == { 'tenant' => 'acme' }
      pattern.params('/acme/projects/other').should be_nil
    end
  end

  context 'with splats' do
    it 'compares the values of multiple splats element-wise' do
      pattern = Mustermann.new('/*/*', repeated_capture: :equal)
      pattern.params('/a/a').should be == { 'splat' => %w[a a] }
      pattern.params('/a/b').should be_nil
    end

    it 'keeps splat params an array' do
      pattern = Mustermann.new('/files/*', repeated_capture: :equal)
      pattern.params('/files/a/b').should be == { 'splat' => ['a/b'] }
    end

    it 'supports named splats used more than once' do
      pattern = Mustermann.new('/*splat/*splat', repeated_capture: :equal)
      pattern.params('/a/a').should be == { 'splat' => %w[a a] }
      pattern.params('/a/b').should be_nil
    end
  end

  context 'with type conversion' do
    it 'compares values after conversion' do
      pattern = Mustermann.new('/:id/x/:id', capture: :integer, repeated_capture: :equal)
      pattern.params('/5/x/05').should be == { 'id' => 5 }
      pattern.params('/5/x/6').should be_nil
    end

    it 'does not match if any conversion fails' do
      pattern = Mustermann.new('/:date/x/:date', capture: :date, repeated_capture: :equal)
      pattern.params('/2021-01-01/x/2021-01-01').should be == { 'date' => Date.new(2021, 1, 1) }
      pattern.params('/2021-99-99/x/2021-99-99').should be_nil
    end
  end

  context 'expanding' do
    it 'only needs one value, encoded the same way at every position' do
      pattern.expand(tenant: 'a b').should be == '/a%20b/projects/a%20b'
    end

    it 'round-trips' do
      expanded = pattern.expand(tenant: 'a b')
      pattern.params(expanded).should be == { 'tenant' => 'a b' }
    end

    it 'round-trips with optional branches' do
      pattern = Mustermann.new('/:tenant(/projects/:tenant)?', repeated_capture: :equal)
      expanded = pattern.expand(tenant: 'acme')
      pattern.params(expanded).should be == { 'tenant' => 'acme' }
    end

    it 'round-trips splats' do
      pattern = Mustermann.new('/*/*', repeated_capture: :equal)
      pattern.params(pattern.expand(splat: 'a')).should be == { 'splat' => %w[a a] }
    end

    it 'works via Mustermann::Expander' do
      expander = Mustermann::Expander.new('/:tenant/projects/:tenant', repeated_capture: :equal)
      expander.expand(tenant: 'a b').should be == '/a%20b/projects/a%20b'
    end
  end

  context 'concatenation' do
    it 'round-trips through native concatenation' do
      pattern = Mustermann.new('/:tenant', repeated_capture: :equal) +
                Mustermann.new('/projects/:tenant', repeated_capture: :equal)
      pattern.params('/acme/projects/%61cme').should be == { 'tenant' => 'acme' }
      pattern.params('/a/projects/b').should be_nil
      expanded = pattern.expand(tenant: 'a b')
      expanded.should be == '/a%20b/projects/a%20b'
      pattern.params(expanded).should be == { 'tenant' => 'a b' }
    end

    it 'enforces equality across Mustermann::Concat patterns' do
      pattern = Mustermann.new('/:tenant', repeated_capture: :equal) +
                Mustermann.new('/projects/:tenant', space_matches_plus: false)
      pattern.class.should be == Mustermann::Concat
      pattern.params('/acme/projects/acme').should be == { 'tenant' => 'acme' }
      pattern.params('/a/projects/b').should be_nil
      pattern.should_not be === '/a/projects/b'
      pattern.peek_params('/acme/projects/acme/rest').should be == [{ 'tenant' => 'acme' }, 19]
      pattern.peek_params('/a/projects/b/rest').should be_nil
      expanded = pattern.expand(tenant: 'a b')
      pattern.params(expanded).should be == { 'tenant' => 'a b' }
    end

    it 'rejects conflicting type converters at pattern construction (native concatenation)' do
      expect {
        Mustermann.new('/:tenant', capture: :integer, repeated_capture: :equal) +
        Mustermann.new('/:tenant', capture: :float, repeated_capture: :equal)
      }.to raise_error(Mustermann::CompileError, 'capture tenant has conflicting type converters')
    end

    it 'rejects conflicting type converters at pattern construction (Mustermann::Concat)' do
      expect {
        Mustermann.new('/:tenant', capture: :integer, repeated_capture: :equal) +
        Mustermann.new('/projects/:tenant', space_matches_plus: false)
      }.to raise_error(Mustermann::CompileError, 'capture tenant has conflicting type converters')
    end

    it 'accepts different spellings of the same converter' do
      pattern = Mustermann.new('/:tenant', capture: :integer, repeated_capture: :equal) +
                Mustermann.new('/projects/:tenant', capture: Integer, repeated_capture: :equal)
      pattern.params('/5/projects/05').should be == { 'tenant' => 5 }
    end
  end

  context 'in a Mustermann::Set' do
    it 'enforces equality with and without trie matching' do
      [true, false].each do |use_trie|
        set = Mustermann::Set.new(use_trie: use_trie)
        set.add(Mustermann.new('/:tenant/projects/:tenant', repeated_capture: :equal))
        set.match('/acme/projects/%61cme')&.params.should be == { 'tenant' => 'acme' }
        set.match('/a/projects/b').should be_nil
      end
    end
  end

  context 'option handling' do
    it 'raises for unknown modes' do
      expect { Mustermann.new('/:tenant', repeated_capture: :collect) }.
        to raise_error(ArgumentError, 'unsupported repeated_capture mode :collect')
    end

    it 'is not supported by non-AST pattern types' do
      expect { Mustermann.new('/:tenant', type: :identity, repeated_capture: :equal) }.
        to raise_error(ArgumentError, /unsupported option/)
    end
  end

  context 'default behavior is unchanged' do
    it 'still rejects duplicate capture names without the option' do
      expect { Mustermann.new('/:foo(/:bar)?/:bar?') }.
        to raise_error(Mustermann::CompileError, "can't use the same capture name twice: \"/:foo(/:bar)?/:bar?\"")
    end

    it 'still collects repeated splats into an array without the option' do
      Mustermann.new('/*/*').params('/a/b').should be == { 'splat' => %w[a b] }
    end

    it 'still expands repeated splats from multiple values without the option' do
      Mustermann.new('/*/*').expand(splat: %w[a b]).should be == '/a/b'
    end
  end
end
