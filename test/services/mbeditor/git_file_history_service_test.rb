# frozen_string_literal: true

require 'test_helper'

module Mbeditor
  class GitFileHistoryServiceTest < Minitest::Test
    REPO_PATH = File.expand_path('../../..', __dir__)

    def test_happy_path_with_gemfile_returns_array_of_commit_hashes
      result = GitFileHistoryService.new(repo_path: REPO_PATH, file_path: 'Gemfile').call

      assert_kind_of Array, result
      refute_empty result

      commit = result.first
      assert commit.key?('hash'),   "commit should have 'hash'"
      assert commit.key?('title'),  "commit should have 'title'"
      assert commit.key?('author'), "commit should have 'author'"
      assert commit.key?('date'),   "commit should have 'date'"
    end

    def test_each_commit_hash_is_40_char_hex_string
      result = GitFileHistoryService.new(repo_path: REPO_PATH, file_path: 'Gemfile').call

      result.each do |commit|
        assert_match(/\A[0-9a-f]{40}\z/, commit['hash'],
                     "hash should be 40 hex chars, got: #{commit['hash'].inspect}")
      end
    end

    def test_non_existent_file_raises_runtime_error
      # git log on a non-existent file exits 0 with empty output, not non-zero,
      # so we test that it returns an empty array rather than raising.
      # (git log --follow -- missing_file exits 0 with no output)
      result = GitFileHistoryService.new(
        repo_path: REPO_PATH,
        file_path: 'this_file_does_not_exist_anywhere_at_all.rb'
      ).call

      assert_kind_of Array, result
      assert_empty result
    end

    # -------------------------------------------------------------------------
    # --follow rename tracking
    # -------------------------------------------------------------------------

    def test_follow_tracks_history_through_a_rename
      Dir.mktmpdir('mbeditor_rename_hist_') do |repo|
        system('git', '-C', repo, 'init', '-q')
        system('git', '-C', repo, 'config', 'user.email', 'test@mbeditor.test')
        system('git', '-C', repo, 'config', 'user.name', 'Test')

        # Commit 1: create original.rb
        File.write(File.join(repo, 'original.rb'), "class Original\nend\n")
        system('git', '-C', repo, 'add', 'original.rb')
        system('git', '-C', repo, 'commit', '-m', 'Add original.rb', '-q')

        # Commit 2: rename to renamed.rb
        FileUtils.mv(File.join(repo, 'original.rb'), File.join(repo, 'renamed.rb'))
        system('git', '-C', repo, 'add', '-A')
        system('git', '-C', repo, 'commit', '-m', 'Rename to renamed.rb', '-q')

        result = GitFileHistoryService.new(repo_path: repo, file_path: 'renamed.rb').call

        assert_kind_of Array, result
        assert_equal 2, result.length, '--follow should surface both the rename commit and the original commit'
        assert_equal 'Rename to renamed.rb', result[0]['title']
        assert_equal 'Add original.rb',      result[1]['title']
      end
    end
  end
end
