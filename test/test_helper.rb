require 'test/unit'
$LOAD_PATH.unshift(File.expand_path(File.join(File.dirname(__FILE__), '..', 'lib')))
$LOAD_PATH.unshift(File.expand_path(File.dirname(__FILE__)))


class Test::Unit::TestCase
  def self.tmpdir
    @@tmpdir ||= Path.setup('tmp/test_tmpdir').find
  end

  def tmpdir
    @tmpdir ||= Test::Unit::TestCase.tmpdir
  end

  setup do
    Open.rm_rf tmpdir
    TmpFile.tmpdir = tmpdir.tmpfiles
    Log::ProgressBar.default_severity = 0
    Persist.cache_dir = tmpdir.var.cache
    Persist::MEMORY_CACHE.clear
    Open.remote_cache_dir = tmpdir.var.cache
    Workflow.directory = tmpdir.var.jobs
    Workflow.workflows.each{|wf| wf.directory = Workflow.directory[wf.name] }
    Entity.entity_property_cache = tmpdir.entity_properties if defined?(Entity)
  end
end
