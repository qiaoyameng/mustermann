# frozen_string_literal: true
require 'support'
require 'mustermann/sinatra'
require 'mustermann/rails'
require 'mustermann/template'
require 'mustermann/ast/node'

describe Mustermann::AST::Explanation do
  def explain(pattern, string, **options)
    pattern.explain_match(string, **options)
  end

  describe 'successful match' do
    subject(:pattern) { Mustermann.new('/foo/:bar') }
    let(:explanation) { explain(pattern, '/foo/baz') }

    it 'matches' do
      expect(explanation).to be_matched
      expect(explanation).not_to be_exhausted
    end

    it 'agrees with a regular match' do
      expect(explanation.matched?).to be == !pattern.match('/foo/baz').nil?
      expect(explanation.params).to be == pattern.params('/foo/baz')
    end

    it 'exposes capture ranges as byte offsets into the original string' do
      capture = explanation.captures['bar']
      expect(capture.name).to  be == 'bar'
      expect(capture.range).to be == (5...8)
      expect(capture.raw).to   be == 'baz'
      expect(capture.value).to be == 'baz'
      expect('/foo/baz'.byteslice(capture.range)).to be == capture.raw
    end

    it 'does not expose failure diagnostics' do
      expect(explanation.position).to be_nil
      expect(explanation.expectations).to be_nil
      expect(explanation.prefix).to be_nil
      expect(explanation.suffix).to be_nil
    end

    it 'has a message and a useful inspect output' do
      expect(explanation.message).to be == '"/foo/:bar" matches "/foo/baz"'
      expect(explanation.to_s).to be == explanation.message
      expect(explanation.inspect).to include('matched').and include('bar')
    end

    it 'keeps raw bytes and decoded values in separate fields' do
      explanation = explain(Mustermann.new('/:name'), '/hello%20world')
      capture = explanation.captures['name']
      expect(capture.range).to be == (1...14)
      expect(capture.raw).to be == 'hello%20world'
      expect(capture.value).to be == 'hello world'
      expect(explanation.params).to be == { 'name' => 'hello world' }
    end

    it 'reports byte ranges, not character ranges, for multibyte input' do
      explanation = explain(Mustermann.new('/foo/:name'), "/foo/\u00fcser")
      capture = explanation.captures['name']
      expect(capture.range).to be == (5...10)
      expect("/foo/\u00fcser".byteslice(capture.range)).to be == "\u00fcser"
      expect(capture.value).to be == "\u00fcser"
    end

    it 'reports a range for every occurrence of repeated captures' do
      explanation = explain(Mustermann.new('/download/*.*'), '/download/file.tar.gz')
      expect(explanation.params).to be == { 'splat' => ['file', 'tar.gz'] }
      first, second = explanation.captures['splat']
      expect(first.range).to be == (10...14)
      expect(first.raw).to be == 'file'
      expect(second.range).to be == (15...21)
      expect(second.raw).to be == 'tar.gz'
    end

    it 'skips captures that did not participate in the match' do
      pattern = Mustermann.new('/:controller(/:action)', type: :rails)
      explanation = explain(pattern, '/users')
      expect(explanation.params).to be == { 'controller' => 'users', 'action' => nil }
      expect(explanation.captures.keys).to be == ['controller']
    end

    it 'matches captures converted via the capture option' do
      pattern = Mustermann::Sinatra.new('/:id', capture: :digit)
      explanation = explain(pattern, '/123')
      expect(explanation.params).to be == { 'id' => '123' }
      expect(explanation.captures['id'].range).to be == (1...4)
    end
  end

  describe 'failed match' do
    it 'agrees with a regular match' do
      pattern = Mustermann.new('/foo/:bar')
      explanation = explain(pattern, '/fo')
      expect(explanation).not_to be_matched
      expect(pattern.match('/fo')).to be_nil
      expect(explanation.params).to be_nil
      expect(explanation.captures).to be_nil
    end

    it 'reports the furthest position and the expected segment' do
      explanation = explain(Mustermann.new('/foo/:bar'), '/fo')
      expect(explanation.position).to be == 3
      expect(explanation.prefix).to be == '/fo'
      expect(explanation.suffix).to be == ''
      expect(explanation.expectations.size).to be == 1
      expectation = explanation.expectations.first
      expect(expectation.description).to be == '"o"'
      expect(expectation.pattern_range).to be == (3...4)
      expect(expectation.to_s).to be == '"o"'
      expect(expectation.inspect).to be == '"o" (pattern 3...4)'
    end

    it 'reports a missing path separator' do
      explanation = explain(Mustermann.new('/foo/bar'), '/foo')
      expect(explanation.position).to be == 4
      expect(explanation.expectations.map(&:description)).to be == ['"/"']
    end

    it 'reports unexpected input at the end of the pattern' do
      explanation = explain(Mustermann.new('/foo'), '/foo/bar')
      expect(explanation.position).to be == 4
      expect(explanation.expectations.map(&:description)).to be == ['end of input']
      expectation = explanation.expectations.first
      expect(expectation.pattern_range).to be_nil
      expect(expectation.inspect).to be == 'end of input'
    end

    it 'reports a failing capture' do
      pattern = Mustermann::Sinatra.new('/:id', capture: :digit)
      explanation = explain(pattern, '/abc')
      expect(explanation.position).to be == 1
      expect(explanation.expectations.map(&:description)).to be == ['capture :id']
    end

    it 'merges expectations from union candidates, keeping pattern ranges' do
      explanation = explain(Mustermann.new('/(foo|bar)/:id'), '/x')
      expect(explanation.position).to be == 1
      expect(explanation.expectations.map(&:description)).to be == ['"f"', '"b"']
      expect(explanation.expectations.map(&:pattern_range)).to be == [(2...3), (6...7)]
    end

    it 'prefers deeper union candidates over shallower ones' do
      explanation = explain(Mustermann.new('/(bar|x)/:id'), '/baz')
      expect(explanation.position).to be == 3
      expect(explanation.expectations.map(&:description)).to be == ['"r"']
    end

    it 'does not let optional branches move the report back to a shorter prefix' do
      explanation = explain(Mustermann.new('/fo(o)?/bar'), '/foox')
      expect(explanation.position).to be == 4
      expect(explanation.expectations.map(&:description)).to be == ['"/"']
    end

    it 'merges expectations from taken and skipped optional branches' do
      explanation = explain(Mustermann.new('/foo(/bar)?/baz'), '/foo/qux')
      expect(explanation.position).to be == 5
      expect(explanation.expectations.map(&:description)).to be == ['"b"', '"b"']
      expect(explanation.expectations.map(&:pattern_range)).to be == [(6...7), (12...13)]
    end

    it 'deduplicates expectations recorded for the same node and position' do
      explanation = explain(Mustermann.new('/a((b)?)?c'), '/ax')
      expect(explanation.position).to be == 2
      expect(explanation.expectations.map(&:description)).to be == ['"b"', '"c"']
    end

    it 'walks into splats to find the furthest position' do
      explanation = explain(Mustermann.new('/download/*.*'), '/download/file')
      expect(explanation.position).to be == 14
      expect(explanation.expectations.map(&:description)).to be == ['"."']
    end

    it 'handles captures compiled with a look ahead' do
      pattern = Mustermann.new('/:a(.)?/x')
      expect(explain(pattern, '/foo./x').params).to be == { 'a' => 'foo' }
      explanation = explain(pattern, '/foo')
      expect(explanation.position).to be == 4
      expect(explanation.expectations.map(&:description)).to be == ['"."', '"/"']
    end

    it 'handles adjacent captures' do
      explanation = explain(Mustermann.new('/:a.:b'), '/')
      expect(explanation.position).to be == 1
      expect(explanation.expectations.map(&:description)).to be == ['capture :a']
    end

    it 'matches all representations of a character' do
      pattern = Mustermann.new('/foo bar')
      expect(explain(pattern, '/foo+bar')).to be_matched
      expect(explain(pattern, '/foo%20bar')).to be_matched
      explanation = explain(pattern, '/fooXbar')
      expect(explanation.position).to be == 4
      expect(explanation.expectations.map(&:description)).to be == ['" "']
    end

    it 'honors uri_decode: false' do
      pattern = Mustermann::Sinatra.new('/foo bar', uri_decode: false)
      expect(explain(pattern, '/foo bar')).to be_matched
      expect(explain(pattern, '/foo+bar')).not_to be_matched
    end

    it 'honors greedy: false' do
      pattern = Mustermann::Sinatra.new('/:a/:b', greedy: false)
      expect(explain(pattern, '/x/y').params).to be == { 'a' => 'x', 'b' => 'y' }
    end

    it 'reports strings rejected by the except option' do
      pattern = Mustermann::Sinatra.new('/foo/:bar', except: '/foo/admin')
      explanation = explain(pattern, '/foo/admin')
      expect(explanation).not_to be_matched
      expect(pattern.match('/foo/admin')).to be_nil
      expect(explanation.position).to be == 10
      expect(explanation.expectations.map(&:description)).to be ==
        ['a string not excluded by the :except option']
    end

    it 'reports template expressions and variables' do
      pattern = Mustermann.new('/foo/{bar}{?q}', type: :template)
      explanation = explain(pattern, '/foo/baz?q=1')
      expect(explanation).to be_matched
      expect(explanation.params).to be == { 'bar' => 'baz', 'q' => '1' }
      expect(explanation.captures['bar'].range).to be == (5...8)
      expect(explanation.captures['q'].range).to be == (11...12)
    end

    it 'reports a failing template variable' do
      pattern = Mustermann.new('/foo/{bar}', type: :template)
      explanation = explain(pattern, '/foo/')
      expect(explanation.position).to be == 5
      expect(explanation.expectations.map(&:description)).to be == ['variable {bar}']
    end

    it 'handles exploded template variables' do
      pattern = Mustermann.new('{/segments*}{?query}', type: :template)
      explanation = explain(pattern, '/a/b/c?query=x')
      expect(explanation).to be_matched
      expect(explanation.params).to be == { 'segments' => ['a', 'b', 'c'], 'query' => 'x' }
    end

    it 'falls back to compiled subexpressions for unknown nodes' do
      char_a  = Mustermann::AST::Node[:char].new(?a)
      char_b  = Mustermann::AST::Node[:char].new(?b)
      wrapper = Mustermann::AST::Node[:node].new(char_a)
      char_a.start,   char_a.stop   = 0, 1
      char_b.start,   char_b.stop   = 1, 2
      wrapper.start,  wrapper.stop  = 0, 1
      root = Mustermann::AST::Node[:root].new
      root.payload = [wrapper, char_b]
      pattern = Mustermann.new('/aab')
      pattern.define_singleton_method(:to_ast) { root }

      explanation = explain(pattern, 'ax')
      expect(explanation.position).to be == 1
      expect(explanation.expectations.map(&:description)).to be == ['"b"']

      explanation = explain(pattern, 'xx')
      expect(explanation.position).to be == 0
      expect(explanation.expectations.map(&:description)).to be == ['node']
    end
  end

  describe 'search budget' do
    subject(:pattern) { Mustermann.new('/:a/:b') }

    it 'stops searching when the budget is exhausted' do
      explanation = explain(pattern, '/x', budget: 1)
      expect(explanation).not_to be_matched
      expect(explanation).to be_exhausted
      expect(explanation.message).to include('(search budget exhausted)')
    end

    it 'handles a zero budget' do
      explanation = explain(pattern, '/x', budget: 0)
      expect(explanation).to be_exhausted
      expect(explanation.position).to be == 0
    end

    it 'does not exhaust the budget for normal input' do
      explanation = explain(pattern, '/x')
      expect(explanation).not_to be_exhausted
      expect(explanation.position).to be == 2
    end

    it 'stays fast for pathological patterns' do
      pattern = Mustermann.new('/' + 'a(b)?' * 20)
      start   = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      explain(pattern, '/' + 'a' * 40)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
      expect(elapsed).to be < 1
    end
  end

  describe 'message' do
    subject(:pattern) { Mustermann.new('/foo') }
    let(:explanation) { explain(pattern, '/foo/admin/token%20secret') }

    it 'does not include the unmatched suffix by default' do
      expect(explanation.message).not_to include('admin')
      expect(explanation.message).not_to include('token')
      expect(explanation.message).to be ==
        '"/foo" does not match: expected end of input at byte 4 (after "/foo")'
    end

    it 'includes the unmatched suffix on demand' do
      expect(explanation.message(include_suffix: true)).to include('/admin/token%20secret')
    end

    it 'exposes the suffix programmatically' do
      expect(explanation.suffix).to be == '/admin/token%20secret'
      expect(explanation.prefix).to be == '/foo'
    end

    it 'has a useful inspect output' do
      expect(explanation.inspect).to include('no match').and include('end of input')
    end
  end

  describe 'consistency with regular matching' do
    {
      '/foo/:bar'              => ['/foo/baz', '/foo', '/fo', '/foo/bar/baz', '/bar/foo'],
      '/:a/:b'                 => ['/x/y', '/x', '/x/y/z', '/'],
        '/foo(/bar)?/:id'      => ['/foo/1', '/foo/bar/1', '/foo/bar', '/foobar/1'],
        '/(foo|bar)/:id'       => ['/foo/1', '/bar/1', '/baz/1', '/foo'],
        '/download/*.*'        => ['/download/f.tar.gz', '/download/f', '/download'],
        '/:controller(/:action)' => ['/users', '/users/show', '/users/show/x'],
    }.each do |pattern_string, strings|
      context "pattern #{pattern_string.inspect}" do
        subject(:pattern) { Mustermann.new(pattern_string) }

        it 'agrees with match and params for all inputs' do
          strings.each do |string|
            explanation = pattern.explain_match(string)
            match       = pattern.match(string)
            expect(explanation.matched?).to be == !match.nil?, "matched? mismatch for #{string.inspect}"
            next unless match
            expect(explanation.params).to be == match.params
            explanation.captures.each_value do |entries|
              entries = [entries] unless entries.is_a? Array
              entries.each do |capture|
                expect(string.byteslice(capture.range)).to be == capture.raw
              end
            end
          end
        end
      end
    end
  end
end
