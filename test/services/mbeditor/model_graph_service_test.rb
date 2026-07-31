# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"

module Mbeditor
  class ModelGraphServiceTest < Minitest::Test
    # The dummy app deliberately does not load ActiveRecord, so these tests
    # require it directly. Association reflection is pure metadata — no
    # database connection is established anywhere below, which is also the
    # guarantee the service itself has to keep.
    begin
      require "active_record"
      AR_AVAILABLE = true
    rescue LoadError
      AR_AVAILABLE = false
    end

    def setup
      skip "activerecord is not available" unless AR_AVAILABLE

      @dir = Dir.mktmpdir("mbeditor_mgs_")
      FileUtils.mkdir_p(File.join(@dir, "app", "models"))
      FileUtils.mkdir_p(File.join(@dir, "tmp"))
      ModelGraphService.invalidate
    end

    def teardown
      ModelGraphService.invalidate
      FileUtils.remove_entry(@dir) if @dir && File.exist?(@dir)
    end

    # Stands in for the reflection surface the service reads, so the tests do
    # not depend on which models happen to be loaded in this process.
    FakeReflection = Struct.new(:name, :macro, :class_name_value, :poly, :options, keyword_init: true) do
      def polymorphic? = poly
      def class_name = class_name_value.is_a?(Proc) ? class_name_value.call : class_name_value
    end

    def fake_model(name, associations: [], table: nil, superclass_name: "ApplicationRecord")
      Class.new do
        define_singleton_method(:name) { name }
        define_singleton_method(:abstract_class?) { false }
        define_singleton_method(:table_name) { table || "#{name.downcase}s" }
        define_singleton_method(:columns) { raise ActiveRecord::ConnectionNotEstablished }
        define_singleton_method(:superclass) { Struct.new(:name).new(superclass_name) }
        define_singleton_method(:reflect_on_all_associations) { associations }
      end
    end

    def assoc(name, macro, target, through: nil, polymorphic: false)
      FakeReflection.new(name: name, macro: macro, class_name_value: target,
                         poly: polymorphic, options: { through: through })
    end

    # Swap the two methods that reach outside this process — discovering loaded
    # AR classes, and eager-loading the host app — for the fake set. Same
    # singleton alias-swap the controller tests use; the suite has no mocking
    # library.
    def build_with(classes)
      singleton = class << ModelGraphService; self; end
      singleton.send(:alias_method, :__orig_model_classes, :model_classes)
      singleton.send(:alias_method, :__orig_eager_load, :eager_load!)
      ModelGraphService.define_singleton_method(:model_classes) { classes }
      ModelGraphService.define_singleton_method(:eager_load!) { nil }

      ModelGraphService.send(:build, @dir)
    ensure
      singleton.send(:remove_method, :model_classes)
      singleton.send(:remove_method, :eager_load!)
      singleton.send(:alias_method, :model_classes, :__orig_model_classes)
      singleton.send(:alias_method, :eager_load!, :__orig_eager_load)
      singleton.send(:remove_method, :__orig_model_classes)
      singleton.send(:remove_method, :__orig_eager_load)
    end

    def test_maps_associations_into_edges_between_models
      author = fake_model("Author", associations: [assoc(:posts, :has_many, "Post")])
      post   = fake_model("Post", associations: [assoc(:author, :belongs_to, "Author")])

      graph = build_with([author, post])

      assert graph[:ok]
      assert_equal %w[Author Post], graph[:models].map { |m| m[:name] }
      assert_equal [%w[Author Post], %w[Post Author]], graph[:edges].map { |e| [e[:from], e[:to]] }
      assert_equal %w[has_many belongs_to], graph[:edges].map { |e| e[:macro] }
    end

    def test_records_the_through_hop_which_the_diagram_cannot_show_structurally
      author = fake_model("Author", associations: [assoc(:comments, :has_many, "Comment", through: :posts)])
      comment = fake_model("Comment")

      edge = build_with([author, comment])[:edges].first

      assert_equal "posts", edge[:through]
    end

    def test_drops_edges_pointing_outside_the_graph
      # A gem's model, or a typo in class_name:, would otherwise render as an
      # arrow into nowhere.
      post = fake_model("Post", associations: [
        assoc(:author, :belongs_to, "Author"),
        assoc(:tenant, :belongs_to, "SomeGem::Tenant")
      ])
      author = fake_model("Author")

      edges = build_with([post, author])[:edges]

      assert_equal ["Author"], edges.map { |e| e[:to] }
    end

    def test_skips_polymorphic_associations_which_have_no_single_target
      comment = fake_model("Comment", associations: [assoc(:commentable, :belongs_to, nil, polymorphic: true)])

      assert_empty build_with([comment])[:edges]
    end

    def test_survives_an_association_whose_class_name_raises
      exploding = assoc(:broken, :belongs_to, -> { raise NameError, "nope" })
      post = fake_model("Post", associations: [exploding, assoc(:author, :belongs_to, "Author")])
      author = fake_model("Author")

      graph = build_with([post, author])

      assert graph[:ok], "one bad association must not cost the whole graph"
      assert_equal ["Author"], graph[:edges].map { |e| e[:to] }
    end

    def test_never_requires_a_database_connection
      # `columns` raises above; the model must still be described, just without
      # its fields — the graph is worth drawing against a database that isn't
      # running or migrated.
      model = build_with([fake_model("Author")])[:models].first

      assert_equal "Author", model[:name]
      assert_equal "authors", model[:table]
      assert_empty model[:columns]
      assert_equal 0, model[:columnCount]
    end

    def test_sends_only_the_first_few_columns_with_the_full_count
      many = Array.new(20) { |i| Struct.new(:name, :type).new("col#{i}", :string) }
      klass = fake_model("Wide")
      klass.define_singleton_method(:columns) { many }

      model = build_with([klass])[:models].first

      assert_equal ModelGraphService::MAX_COLUMNS_SENT, model[:columns].length,
                   "the box shows a few; the rest are a click away in the schema modal"
      assert_equal 20, model[:columnCount], "but the box still says how many there really are"
      assert_equal({ name: "col0", type: "string" }, model[:columns].first)
    end

    def test_reports_a_reason_when_there_are_no_models
      graph = build_with([])

      refute graph[:ok]
      assert_match(/no activerecord models/i, graph[:error])
      assert_empty graph[:models]
    end

    def test_writes_mermaid_and_json_artifacts_to_tmp
      author = fake_model("Author", associations: [assoc(:posts, :has_many, "Post")])
      post   = fake_model("Post", associations: [assoc(:author, :belongs_to, "Author")])

      payload = build_with([author, post])
      ModelGraphService.send(:write_artifacts, @dir, payload)

      mmd = File.read(File.join(@dir, "tmp", "mbeditor_model_graph.mmd"))
      assert_match(/\AerDiagram/, mmd)
      assert_includes mmd, "Author ||--o{ Post : \"posts\""
      assert_includes mmd, "Post }o--|| Author : \"author\""

      json = JSON.parse(File.read(File.join(@dir, "tmp", "mbeditor_model_graph.json")))
      assert_equal %w[Author Post], json["models"].map { |m| m["name"] }
    end

    def test_mermaid_ids_strip_namespacing_which_mermaid_cannot_parse
      mmd = ModelGraphService.send(:to_mermaid, {
        models: [{ name: "Admin::User" }],
        edges: [{ from: "Admin::User", to: "Admin::User", macro: "has_many", name: "children", through: nil }]
      })

      refute_includes mmd, "::"
      assert_includes mmd, "Admin_User"
    end

    def test_fingerprint_changes_when_a_model_file_is_saved
      path = File.join(@dir, "app", "models", "user.rb")
      File.write(path, "class User; end\n")
      before = ModelGraphService.fingerprint_for(@dir)

      File.write(File.join(@dir, "app", "models", "post.rb"), "class Post; end\n")
      after_new_file = ModelGraphService.fingerprint_for(@dir)
      refute_equal before, after_new_file, "a new model must invalidate the cache"

      FileUtils.touch(path, mtime: Time.now + 60)
      refute_equal after_new_file, ModelGraphService.fingerprint_for(@dir), "a saved model must too"
    end

    def test_fingerprint_covers_migrations
      FileUtils.mkdir_p(File.join(@dir, "db", "migrate"))
      before = ModelGraphService.fingerprint_for(@dir)
      File.write(File.join(@dir, "db", "migrate", "001_create_users.rb"), "class CreateUsers; end\n")

      refute_equal before, ModelGraphService.fingerprint_for(@dir)
    end

    def test_fingerprint_is_stable_when_nothing_changes
      assert_equal ModelGraphService.fingerprint_for(@dir), ModelGraphService.fingerprint_for(@dir)
    end
  end
end
