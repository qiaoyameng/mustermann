# frozen_string_literal: true
require 'support'
require 'mustermann'
require 'mustermann/sinatra'

describe 'repeated_capture: :equal' do
  describe 'option handling' do
    it 'is supported by AST-based patterns' do
      expect(Mustermann::Sinatra.supported?(:repeated_capture)).to be(true)
    end

    it 'raises ArgumentError for unknown modes' do
      expect { Mustermann.new('/:a', repeated_capture: :foo) }.
        to raise_error(ArgumentError, 'unsupported repeated_capture mode :foo, expected :equal')
    end

    it 'is rejected for patterns not supporting the option' do
      expect { Mustermann.new('/:a', type: :identity, repeated_capture: :equal) }.
        to raise_error(ArgumentError)
    end

    it 'keeps the default repeated capture handling without the option' do
      # simple patterns historically compile to duplicate named groups, last match wins
      pattern = Mustermann.new('/:tenant/projects/:tenant')
      expect(pattern.params('/a/projects/b')).to be == { 'tenant' => 'b' }
      expect(pattern === '/a/projects/b').to be(true)
    end

    it 'keeps rejecting repeated names in non-simple patterns without the option' do
      expect { Mustermann.new('/:tenant/projects/:tenant/') }.
        to raise_error(Mustermann::CompileError, /can't use the same capture name twice/)
    end
  end

  describe 'matching' do
    subject(:pattern) { Mustermann.new('/:tenant/projects/:tenant', repeated_capture: :equal) }

    it 'matches when both occurrences capture the same value' do
      expect(pattern === '/acme/projects/acme').to be(true)
      expect(pattern.params('/acme/projects/acme')).to be == { 'tenant' => 'acme' }
    end

    it 'compares values after URI decoding, so different encodings of one value match' do
      expect(pattern === '/acme/projects/%61cme').to be(true)
      expect(pattern === '/%61cme/projects/acme').to be(true)
      expect(pattern.params('/acme/projects/%61cme')).to be == { 'tenant' => 'acme' }
      expect(pattern.params('/acme/projects/%61%63me')).to be == { 'tenant' => 'acme' }
    end

    it 'does not match when the decoded values differ' do
      expect(pattern === '/acme/projects/other').to be(false)
      expect(pattern === '/acme/projects/%6Fther').to be(false)
      expect(pattern.match('/acme/projects/other')).to be_nil
      expect(pattern.params('/acme/projects/other')).to be_nil
      expect(pattern =~ '/acme/projects/other').to be_nil
      expect(pattern =~ '/acme/projects/acme').to be(0)
    end

    it 'applies the constraint to peek matching as well' do
      expect(pattern.peek_size('/acme/projects/acme/rest')).to be(19)
      expect(pattern.peek_size('/acme/projects/other/rest')).to be_nil
      expect(pattern.peek_params('/acme/projects/acme/rest')).to be == [{ 'tenant' => 'acme' }, 19]
      expect(pattern.peek_params('/acme/projects/other/rest')).to be_nil
    end

    it 'handles non-string input like the default implementation' do
      expect(pattern === nil).to be(false)
      expect(pattern =~ nil).to be_nil
    end

    it 'compares values after param conversion' do
      pattern = Mustermann.new('/:n/x/:n', repeated_capture: :equal, capture: :integer)
      expect(pattern.params('/1/x/01')).to be == { 'n' => 1 }
      expect(pattern.params('/1/x/2')).to be_nil
    end

    it 'treats a failed param conversion as no match' do
      pattern = Mustermann.new('/:d/x/:d', repeated_capture: :equal, capture: :date)
      expect(pattern.params('/2021-01-01/x/2021-01-01')).to be == { 'd' => Date.new(2021, 1, 1) }
      expect(pattern.params('/2021-13-99/x/2021-13-99')).to be_nil
      expect(pattern === '/2021-13-99/x/2021-13-99').to be(false)
    end
  end

  describe 'optional captures' do
    subject(:pattern) { Mustermann.new('/:tenant(/projects/:tenant)?', repeated_capture: :equal) }

    it 'does not constrain captures in optional branches that did not participate' do
      expect(pattern.params('/acme')).to be == { 'tenant' => 'acme' }
      expect(pattern.params('/acme/projects/acme')).to be == { 'tenant' => 'acme' }
      expect(pattern.params('/acme/projects/other')).to be_nil
    end
  end

  describe 'splats' do
    it 'compares multiple named splats element wise' do
      pattern = Mustermann.new('/*repo/files/*repo', repeated_capture: :equal)
      expect(pattern.params('/a/b/files/a/b')).to be == { 'repo' => 'a/b' }
      expect(pattern.params('/a/b/files/a/c')).to be_nil
      expect(pattern.params('/a%2Fb/files/a/b')).to be == { 'repo' => 'a/b' }
    end

    it 'compares multiple unnamed splats element wise' do
      pattern = Mustermann.new('/*/files/*', repeated_capture: :equal)
      expect(pattern.params('/a/b/files/a/b')).to be == { 'splat' => ['a/b'] }
      expect(pattern.params('/a/b/files/a/c')).to be_nil
    end
  end

  describe 'expansion' do
    subject(:pattern) { Mustermann.new('/:tenant/projects/:tenant', repeated_capture: :equal) }

    it 'expands a single value to all occurrences' do
      expect(pattern.expand(tenant: 'acme')).to be == '/acme/projects/acme'
    end

    it 'uses the same encoding at every occurrence' do
      expect(pattern.expand(tenant: 'a b')).to be == '/a%20b/projects/a%20b'
    end

    it 'round-trips with params' do
      expanded = pattern.expand(tenant: 'a b')
      expect(pattern.params(expanded)).to be == { 'tenant' => 'a b' }
    end

    it 'expands splats with a single value' do
      pattern = Mustermann.new('/*repo/files/*repo', repeated_capture: :equal)
      expect(pattern.expand(repo: 'a/b')).to be == '/a/b/files/a/b'
      expect(pattern.params(pattern.expand(repo: 'a/b'))).to be == { 'repo' => 'a/b' }
    end

    it 'works through Mustermann::Expander' do
      expander = Mustermann::Expander.new('/:tenant/projects/:tenant', repeated_capture: :equal)
      expect(expander.expand(tenant: 'acme')).to be == '/acme/projects/acme'
    end
  end

  describe 'Mustermann::Set' do
    it 'enforces the constraint with the linear matcher' do
      set = Mustermann::Set.new(use_trie: false)
      set.add(Mustermann.new('/:tenant/projects/:tenant', repeated_capture: :equal))
      expect(set.match('/acme/projects/acme').params).to be == { 'tenant' => 'acme' }
      expect(set.match('/acme/projects/other')).to be_nil
    end

    it 'falls back to the linear matcher instead of ignoring the constraint in trie mode' do
      set = Mustermann::Set.new(use_trie: true)
      set.add(Mustermann.new('/:tenant/projects/:tenant', repeated_capture: :equal))
      expect(set.match('/acme/projects/acme').params).to be == { 'tenant' => 'acme' }
      expect(set.match('/acme/projects/other')).to be_nil
    end

    it 'keeps using the trie for patterns without repeated captures' do
      set = Mustermann::Set.new(use_trie: true)
      set.add(Mustermann.new('/:a/:b', repeated_capture: :equal))
      expect(set.match('/x/y').params).to be == { 'a' => 'x', 'b' => 'y' }
    end
  end

  describe 'pattern concatenation' do
    let(:prefix)  { Mustermann.new('/:tenant', repeated_capture: :equal) }
    let(:suffix)  { Mustermann.new('/projects/:tenant', repeated_capture: :equal) }

    it 'combines natively when options match' do
      pattern = prefix + suffix
      expect(pattern).to be_a(Mustermann::Sinatra)
      expect(pattern.params('/acme/projects/%61cme')).to be == { 'tenant' => 'acme' }
      expect(pattern.params('/acme/projects/other')).to be_nil
      expect(pattern.expand(tenant: 'acme')).to be == '/acme/projects/acme'
      expect(pattern.params(pattern.expand(tenant: 'acme'))).to be == { 'tenant' => 'acme' }
    end

    it 'enforces equality across subpatterns of a Mustermann::Concat' do
      pattern = Mustermann::Concat.new(prefix, suffix)
      expect(pattern === '/acme/projects/acme').to be(true)
      expect(pattern === '/acme/projects/other').to be(false)
      expect(pattern.params('/acme/projects/acme')).to be == { 'tenant' => 'acme' }
      expect(pattern.params('/acme/projects/other')).to be_nil
      expect(pattern.match('/acme/projects/other')).to be_nil
      expect(pattern.peek_params('/acme/projects/other/x')).to be_nil
      expect(pattern.peek_params('/acme/projects/acme/x')).to be == [{ 'tenant' => 'acme' }, 19]
    end

    it 'expands a Mustermann::Concat with a single value' do
      pattern = Mustermann::Concat.new(prefix, suffix)
      expect(pattern.expand(tenant: 'acme')).to be == '/acme/projects/acme'
      expect(pattern.params(pattern.expand(tenant: 'acme'))).to be == { 'tenant' => 'acme' }
    end

    it 'still rejects repeated names in concatenations without the option' do
      expect { Mustermann::Concat.new(Mustermann.new('/:tenant'), Mustermann.new('/projects/:tenant')) }.
        to raise_error(Mustermann::CompileError, /can't use the same capture name twice/)
    end
  end
end
