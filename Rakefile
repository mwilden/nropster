require 'rake'
require 'spec/rake/spectask'

desc "Run all specs"
Spec::Rake::SpecTask.new(:spec) do |t|
  t.spec_opts = ['--options', '"spec/spec.opts"']
  t.spec_files = FileList['spec/**/*.rb']
end

task :default => [:spec]

task :metrics do
  gem 'flog'
  gem 'facets'
  gem 'reek'
  gem 'relevance-rcov'
  gem 'rmagick'
  gem 'roodi'
  gem 'ruby2ruby'
  gem 'ruby_parser'
  gem 'sexp_processor'
  gem 'topfunky-gruff'
  gem "mwilden-metric_fu"
  require 'metric_fu'

  Rake::Task["metrics:all"].execute
end
