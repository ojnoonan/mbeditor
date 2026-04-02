# frozen_string_literal: true

require 'test_helper'

module Mbeditor
  class GitCommitGraphServiceTest < Minitest::Test
    REPO_PATH = File.expand_path('../../..', __dir__)

    def service
      GitCommitGraphService.new(repo_path: REPO_PATH)
    end

    def test_happy_path_returns_non_empty_array
      result = service.call
      assert_kind_of Array, result
      refute_empty result
    end

    def test_each_entry_has_expected_keys
      result = service.call
      entry = result.first

      assert entry.key?('hash'),    "entry should have 'hash'"
      assert entry.key?('parents'), "entry should have 'parents'"
      assert entry.key?('title'),   "entry should have 'title'"
      assert entry.key?('author'),  "entry should have 'author'"
      assert entry.key?('date'),    "entry should have 'date'"
      assert entry.key?('isLocal'), "entry should have 'isLocal'"
      assert_kind_of Array, entry['parents']
    end

    def test_is_local_is_a_boolean
      result = service.call
      result.each do |entry|
        assert_includes [true, false], entry['isLocal'],
                        "isLocal should be true or false, got #{entry['isLocal'].inspect}"
      end
    end

    def test_result_length_does_not_exceed_max_commits
      result = service.call
      assert_operator result.length, :<=, GitCommitGraphService::MAX_COMMITS
    end

    def test_merge_commits_have_multiple_parents
      result = service.call
      merge_commits = result.select { |c| c['parents'].length > 1 }
      refute_empty merge_commits, 'expected at least one merge commit with multiple parents in the project history'
    end

    # -------------------------------------------------------------------------
    # isLocal flag — unit-level test using a temp repo with no upstream
    # -------------------------------------------------------------------------

    def test_is_local_false_for_all_commits_when_no_upstream_configured
      Dir.mktmpdir('mbeditor_graph_noupstream_') do |repo|
        system('git', '-C', repo, 'init', '-q')
        system('git', '-C', repo, 'config', 'user.email', 'test@mbeditor.test')
        system('git', '-C', repo, 'config', 'user.name', 'Test')
        File.write(File.join(repo, 'README.md'), "hello\n")
        system('git', '-C', repo, 'add', '.')
        system('git', '-C', repo, 'commit', '-m', 'init', '-q')

        result = GitCommitGraphService.new(repo_path: repo).call

        refute_empty result
        assert result.all? { |c| c['isLocal'] == false },
               'with no upstream, local_commit_shas returns empty set so isLocal must be false'
      end
    end

    def test_is_local_true_for_commits_ahead_of_upstream
      Dir.mktmpdir('mbeditor_graph_local_') do |upstream_dir|
        Dir.mktmpdir('mbeditor_graph_clone_') do |clone_dir|
          # Bare upstream with one commit
          system('git', '-C', upstream_dir, 'init', '--bare', '-q')

          system('git', 'clone', '--quiet', upstream_dir, clone_dir)
          system('git', '-C', clone_dir, 'config', 'user.email', 'test@mbeditor.test')
          system('git', '-C', clone_dir, 'config', 'user.name', 'Test')

          # Push an initial commit so upstream is set up
          File.write(File.join(clone_dir, 'README.md'), "hello\n")
          system('git', '-C', clone_dir, 'add', '.')
          system('git', '-C', clone_dir, 'commit', '-m', 'init', '-q')
          system('git', '-C', clone_dir, 'push', 'origin', 'HEAD', '-q')

          # Add a local commit (not pushed)
          File.write(File.join(clone_dir, 'local.rb'), "x = 1\n")
          system('git', '-C', clone_dir, 'add', 'local.rb')
          system('git', '-C', clone_dir, 'commit', '-m', 'local only commit', '-q')

          result = GitCommitGraphService.new(repo_path: clone_dir).call

          local_entries = result.select { |c| c['isLocal'] }
          refute_empty local_entries, 'the unpushed commit should have isLocal: true'
          assert_equal 'local only commit', local_entries.first['title']
        end
      end
    end
  end
end
