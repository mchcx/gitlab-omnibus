require 'chef_helper'

describe 'gitlab::gitlab-rails' do
  let(:chef_run) { ChefSpec::SoloRunner.new(step_into: %w(templatesymlink)).converge('gitlab::default') }

  before do
    allow(Gitlab).to receive(:[]).and_call_original
    allow(File).to receive(:symlink?).and_call_original
  end

  context 'when manage-storage-directories is disabled' do
    cached(:chef_run) do
      RSpec::Mocks.with_temporary_scope do
        stub_gitlab_rb(gitlab_rails: { shared_path: '/tmp/shared',
                                       uploads_directory: '/tmp/uploads',
                                       builds_directory: '/tmp/builds' },
                       manage_storage_directories: { enable: false })
      end

      ChefSpec::SoloRunner.new(step_into: %w(templatesymlink)).converge('gitlab::default')
    end

    it 'does not create the shared directory' do
      expect(chef_run).not_to run_ruby_block('directory resource: /tmp/shared')
    end

    it 'does not create the artifacts directory' do
      expect(chef_run).not_to run_ruby_block('directory resource: /tmp/shared/artifacts')
    end

    it 'does not create the lfs storage directory' do
      expect(chef_run).not_to run_ruby_block('directory resource: /tmp/shared/lfs-objects')
    end

    it 'does not create the uploads storage directory' do
      expect(chef_run).not_to run_ruby_block('directory resource: /tmp/uploads')
    end

    it 'does not create the ci builds directory' do
      expect(chef_run).not_to run_ruby_block('directory resource: /tmp/builds')
    end

    it 'does not create the GitLab pages directory' do
      expect(chef_run).not_to run_ruby_block('directory resource: /tmp/shared/pages')
    end
  end

  context 'when manage-storage-directories is enabled' do
    cached(:chef_run) do
      RSpec::Mocks.with_temporary_scope do
        stub_gitlab_rb(gitlab_rails: { shared_path: '/tmp/shared',
                                       uploads_directory: '/tmp/uploads' },
                       gitlab_ci: { builds_directory: '/tmp/builds' })
      end

      ChefSpec::SoloRunner.new(step_into: %w(templatesymlink)).converge('gitlab::default')
    end

    it 'creates the shared directory' do
      expect(chef_run).to run_ruby_block('directory resource: /tmp/shared')
    end

    it 'creates the artifacts directory' do
      expect(chef_run).to run_ruby_block('directory resource: /tmp/shared/artifacts')
    end

    it 'creates the lfs storage directory' do
      expect(chef_run).to run_ruby_block('directory resource: /tmp/shared/lfs-objects')
    end

    it 'creates the uploads directory' do
      expect(chef_run).to run_ruby_block('directory resource: /tmp/uploads')
    end

    it 'creates the ci builds directory' do
      expect(chef_run).to run_ruby_block('directory resource: /tmp/builds')
    end

    it 'creates the GitLab pages directory' do
      expect(chef_run).to run_ruby_block('directory resource: /tmp/shared/pages')
    end
  end

  context 'with redis settings' do
    let(:config_file) { '/var/opt/gitlab/gitlab-rails/etc/resque.yml' }

    context 'and default configuration' do
      it 'creates the config file with the required redis settings' do
        expect(chef_run).to render_file(config_file)
                              .with_content(%r{url: unix:/var/opt/gitlab/redis/redis.socket})
      end
    end

    context 'and custom configuration' do
      before do
        stub_gitlab_rb(
          gitlab_rails: {
            redis_host: 'redis.example.com',
            redis_port: 8888,
            redis_database: 2,
            redis_password: 'mypass'
          }
        )
      end

      it 'creates the config file with custom host, port, password and database' do
        expect(chef_run).to render_file(config_file)
                              .with_content(%r{url: redis://:mypass@redis.example.com:8888/2})
      end
    end
  end

  context 'creating gitlab.yml' do
    gitlab_yml_path = '/var/opt/gitlab/gitlab-rails/etc/gitlab.yml'
    let(:gitlab_yml) { chef_run.template(gitlab_yml_path) }

    # NOTE: Test if we pass proper notifications to other resources
    context 'rails cache management' do
      before do
        allow_any_instance_of(OmnibusHelper).to receive(:not_listening?)
          .and_return(false)
      end

      it 'should notify rails cache clear resource' do
        expect(gitlab_yml).to notify('execute[clear the gitlab-rails cache]')
      end

      it 'should still notify rails cache clear resource if disabled' do
        stub_gitlab_rb(gitlab_rails: { rake_cache_clear: false })

        expect(gitlab_yml).to notify(
          'execute[clear the gitlab-rails cache]')
        expect(gitlab_yml).not_to run_execute(
          'clear the gitlab-rails cache')
      end
    end

    context 'for settings regarding object storage for artifacts' do
      it 'allows not setting any values' do
        expect(chef_run).to render_file(gitlab_yml_path)
            .with_content(/object_store:\s+enabled: false\s+remote_directory: "artifacts"\s+connection:/)
      end

      it 'sets the connection in YAML' do
        json = <<~JSON
        {
          'provider' => 'AWS',
          'region' => 'eu-west-1',
          'aws_access_key_id' => 'AKIAKIAKI',
          'aws_secret_access_key' => 'secret123'
        }
        JSON

        stub_gitlab_rb(gitlab_rails: {
                         artifacts_object_store_enabled: true,
                         artifacts_object_store_remote_directory: 'mepmep',
                         artifacts_object_store_connection: json
                       })

        expect(chef_run).to render_file(gitlab_yml_path)
            .with_content(/object_store:\s+enabled: true\s+remote_directory:\s+"mepmep"/)
        expect(chef_run).to render_file(gitlab_yml_path)
          .with_content(/connection:\s"{\\n  'provider' => 'AWS'/)
        expect(chef_run).to render_file(gitlab_yml_path)
          .with_content(/'region' => 'eu-west-1'/)
        expect(chef_run).to render_file(gitlab_yml_path)
          .with_content(/'aws_access_key_id' => 'AKIAKIAKI'/)
        expect(chef_run).to render_file(gitlab_yml_path)
          .with_content(/'aws_secret_access_key' => 'secret123'/)
      end
    end

    describe 'repositories storages' do
      it 'sets specified properties' do
        stub_gitlab_rb(
          git_data_dirs: {
            "second_storage" => {
              "path" => "tmp/storage",
              "failure_count_threshold" => 15,
            }
          }
        )

        expect(chef_run).to render_file(gitlab_yml_path).with_content('"path":"tmp/storage/repositories"')
        expect(chef_run).to render_file(gitlab_yml_path).with_content('"failure_count_threshold":15')
      end

      it 'sets the defaults' do
        default_json = '{"default":{"path":"/var/opt/gitlab/git-data/repositories","gitaly_address":"unix:/var/opt/gitlab/gitaly/gitaly.socket","failure_count_threshold":10,"failure_wait_time":30,"failure_reset_time":1800,"storage_timeout":30}}'
        expect(chef_run).to render_file(gitlab_yml_path).with_content(default_json)
      end
    end

    context 'mattermost settings' do
      context 'mattermost is configured' do
        it 'exposes the mattermost host' do
          stub_gitlab_rb(mattermost: { enable: true },
                         mattermost_external_url: 'http://mattermost.domain.com')

          expect(chef_run).to render_file(gitlab_yml_path)
            .with_content("host: http://mattermost.domain.com")
        end
      end

      context 'mattermost is not configured' do
        it 'has empty values' do
          expect(chef_run).to render_file(gitlab_yml_path)
            .with_content(/mattermost:\s+enabled: false\s+host:\s+/)
        end
      end

      context 'mattermost on another server' do
        it 'sets the mattermost host' do
          stub_gitlab_rb(gitlab_rails: { mattermost_host: 'http://my.host.com' })

          expect(chef_run).to render_file(gitlab_yml_path)
            .with_content(/mattermost:\s+enabled: true\s+host: http:\/\/my.host.com\s+/)
        end

        context 'values set twice' do
          it 'sets the mattermost external url' do
            stub_gitlab_rb(mattermost: { enable: true },
                           mattermost_external_url: 'http://my.url.com',
                           gitlab_rails: { mattermost_host: 'http://do.not/setme' })

            expect(chef_run).to render_file(gitlab_yml_path)
              .with_content(/mattermost:\s+enabled: true\s+host: http:\/\/my.url.com\s+/)
          end
        end
      end
    end

    context 'omniauth settings' do
      context 'sync email from omniauth provider is configured' do
        it 'sets the omniauth provider' do
          stub_gitlab_rb(gitlab_rails: { omniauth_sync_email_from_provider: 'cas3' })

          expect(chef_run).to render_file(gitlab_yml_path)
            .with_content("sync_email_from_provider: \"cas3\"")
        end
      end

      context 'sync email from omniauth provider is not configured' do
        it 'does not include the sync email from omniauth provider setting' do
          expect(chef_run).to render_file(gitlab_yml_path).with_content { |content|
            expect(content).not_to include('sync_email_from_provider')
          }
        end
      end
    end

    context 'GitLab Geo settings' do
      let(:chef_run) do
        ChefSpec::SoloRunner.new(step_into: %w(templatesymlink)).converge('gitlab-ee::default')
      end

      context 'by default' do
        it 'geo_primary_role is disabled' do
          expect(chef_run).to render_file(gitlab_yml_path)
            .with_content(%r{geo_primary_role:\s+enabled: false})
        end

        it 'geo_secondary_role is disabled' do
          expect(chef_run).to render_file(gitlab_yml_path)
            .with_content(%r{geo_secondary_role:\s+enabled: false})
        end
      end

      context 'when geo_primary_role is enabled' do
        it 'enables geo_primary_role in config' do
          stub_gitlab_rb(geo_primary_role: { enable: true })

          expect(chef_run).to render_file(gitlab_yml_path)
            .with_content(%r{geo_primary_role:\s+enabled: true})
        end
      end

      context 'when geo_secondary_role is enabled' do
        it 'enables geo_secondary_role in config' do
          stub_gitlab_rb(geo_secondary_role: { enable: true }, geo_postgresql: { data_dir: 'foo' })

          expect(chef_run).to render_file(gitlab_yml_path)
            .with_content(%r{geo_secondary_role:\s+enabled: true})
        end
      end

      context 'when repository sync worker is configured' do
        it 'sets the cron value' do
          stub_gitlab_rb(gitlab_rails: { geo_repository_sync_worker_cron: '1 2 3 4 5' })

          expect(chef_run).to render_file(gitlab_yml_path)
            .with_content(/geo_repository_sync_worker:\s+cron:\s+"1 2 3 4 5"/)
        end
      end

      context 'when repository sync worker is not configured' do
        it 'does not set the cron value' do
          expect(chef_run).to render_file(gitlab_yml_path).with_content { |content|
            expect(content).not_to include('geo_repository_sync_worker')
          }
        end
      end

      context 'when file download dispatch worker is configured' do
        it 'sets the cron value' do
          stub_gitlab_rb(gitlab_rails: { geo_file_download_dispatch_worker_cron: '1 2 3 4 5' })

          expect(chef_run).to render_file(gitlab_yml_path)
            .with_content(/geo_file_download_dispatch_worker:\s+cron:\s+"1 2 3 4 5"/)
        end
      end

      context 'when file download dispatch worker is not configured' do
        it 'does not set the cron value' do
          expect(chef_run).to render_file(gitlab_yml_path).with_content { |content|
            expect(content).not_to include('geo_file_download_dispatch_worker')
          }
        end
      end
    end

    context 'Scheduled Pipeline settings' do
      context 'when the cron pattern is configured' do
        it 'sets the cron value' do
          stub_gitlab_rb(gitlab_rails: { pipeline_schedule_worker_cron: '41 * * * *' })

          expect(chef_run).to render_file(gitlab_yml_path)
            .with_content(/pipeline_schedule_worker:\s+cron:\s+"41/)
        end
      end

      context 'when the cron pattern is not configured' do
        it 'sets no value' do
          expect(chef_run).to render_file(gitlab_yml_path)
            .with_content(/pipeline_schedule_worker:\s+cron:\s[^"]+/)
        end
      end
    end

    context 'Monitoring settings' do
      context 'by default' do
        it 'whitelists local subnet' do
          expect(chef_run).to render_file(gitlab_yml_path)
                                .with_content(%r{monitoring:\s+(.+\s+){3}ip_whitelist:\s+- 127.0.0.0/8})
        end
        it 'sampler will sample every 10s' do
          expect(chef_run).to render_file(gitlab_yml_path)
                                .with_content(%r{monitoring:\s+(.+\s+)unicorn_sampler_interval: 10})
        end
      end

      context 'when ip whitelist is configured' do
        before do
          stub_gitlab_rb(gitlab_rails: { monitoring_whitelist: %w(1.0.0.0 2.0.0.0) })
        end
        it 'sets the whitelist' do
          expect(chef_run).to render_file(gitlab_yml_path)
                                .with_content(%r{monitoring:\s+(.+\s+){3}ip_whitelist:\s+- 1.0.0.0\s+- 2.0.0.0})
        end
      end

      context 'when unicorn sampler interval is configured' do
        before do
          stub_gitlab_rb(gitlab_rails: { monitoring_unicorn_sampler_interval: 123 })
        end

        it 'sets the interval value' do
          expect(chef_run).to render_file(gitlab_yml_path)
                                .with_content(%r{monitoring:\s+(.+\s+)unicorn_sampler_interval: 123})
        end
      end
    end

    context 'Gitaly settings' do
      context 'when a global token is set' do
        let(:token) { '123secret456gitaly' }

        it 'renders the token in the gitaly section' do
          stub_gitlab_rb(gitlab_rails: { gitaly_token: token })

          expect(chef_run).to render_file(gitlab_yml_path)
            .with_content(%r{gitaly:\s+token: "#{token}"})
        end
      end
    end

    context 'GitLab Shell settings' do
      context 'when git_timeout is configured' do
        it 'sets the git_timeout value' do
          stub_gitlab_rb(gitlab_rails: { gitlab_shell_git_timeout: '1000' })

          expect(chef_run).to render_file(gitlab_yml_path)
            .with_content(/git_timeout:\s+1000/)
        end
      end

      context 'when git_timeout is not configured' do
        it 'sets git_timeout value to default' do
          expect(chef_run).to render_file(gitlab_yml_path)
            .with_content(/git_timeout:\s+800/)
        end
      end
    end

    context 'when there is a legacy GitLab Rails stuck_ci_builds_worker_cron key' do
      before do
        allow(Gitlab).to receive(:[]).and_call_original
        stub_gitlab_rb(gitlab_rails: { stuck_ci_builds_worker_cron: '0 1 2 * *' })
      end

      it 'warns that this value is deprecated' do
        allow(Chef::Log).to receive(:warn).and_call_original
        expect(Chef::Log).to receive(:warn).with(/gitlab_rails\['stuck_ci_builds_worker_cron'\]/)

        chef_run
      end

      it 'copies legacy value from legacy key to new one' do
        chef_run

        expect(Gitlab['gitlab_rails']['stuck_ci_jobs_worker_cron']).to eq('0 1 2 * *')
      end
    end

    context 'GitLab LDAP cron_jobs settings' do
      context 'when ldap user sync worker is configured' do
        it 'sets the cron value' do
          stub_gitlab_rb(gitlab_rails: { ldap_sync_worker_cron: '40 2 * * *' })

          expect(chef_run).to render_file(gitlab_yml_path)
            .with_content(/ldap_sync_worker:\s+cron:\s+"40 2 \* \* \*"/)
        end
      end

      context 'when ldap user sync worker is not configured' do
        it 'does not set the cron value' do
          expect(chef_run).to render_file(gitlab_yml_path).with_content { |content|
            expect(content).not_to include('ldap_sync_worker')
          }
        end
      end

      context 'when ldap group sync worker is configured' do
        it 'sets the cron value' do
          stub_gitlab_rb(gitlab_rails: { ldap_group_sync_worker_cron: '1 0 * * *' })

          expect(chef_run).to render_file(gitlab_yml_path)
            .with_content(/ldap_group_sync_worker:\s+cron:\s+"1 0 \* \* \*"/)
        end
      end

      context 'when ldap group sync worker is not configured' do
        it 'does not set the cron value' do
          expect(chef_run).to render_file(gitlab_yml_path).with_content { |content|
            expect(content).not_to include('ldap_group_sync_worker')
          }
        end
      end
    end
  end

  context 'with environment variables' do
    context 'by default' do
      it_behaves_like "enabled gitlab-rails env", "HOME", '\/var\/opt\/gitlab'
      it_behaves_like "enabled gitlab-rails env", "RAILS_ENV", 'production'
      it_behaves_like "enabled gitlab-rails env", "SIDEKIQ_MEMORY_KILLER_MAX_RSS", '1000000'
      it_behaves_like "enabled gitlab-rails env", "BUNDLE_GEMFILE", '\/opt\/gitlab\/embedded\/service\/gitlab-rails\/Gemfile'
      it_behaves_like "enabled gitlab-rails env", "PATH", '\/opt\/gitlab\/bin:\/opt\/gitlab\/embedded\/bin:\/bin:\/usr\/bin'
      it_behaves_like "enabled gitlab-rails env", "ICU_DATA", '\/opt\/gitlab\/embedded\/share\/icu\/current'
      it_behaves_like "enabled gitlab-rails env", "PYTHONPATH", '\/opt\/gitlab\/embedded\/lib\/python3.4\/site-packages'

      it_behaves_like "enabled gitlab-rails env", "LD_PRELOAD", '\/opt\/gitlab\/embedded\/lib\/libjemalloc.so'
      it_behaves_like "disabled gitlab-rails env", "RAILS_RELATIVE_URL_ROOT", ''

      context 'when a custom env variable is specified' do
        before do
          stub_gitlab_rb(gitlab_rails: { env: { 'IAM' => 'CUSTOMVAR' } })
        end

        it_behaves_like "enabled gitlab-rails env", "IAM", 'CUSTOMVAR'
        it_behaves_like "enabled gitlab-rails env", "ICU_DATA", '\/opt\/gitlab\/embedded\/share\/icu\/current'
        it_behaves_like "enabled gitlab-rails env", "LD_PRELOAD", '\/opt\/gitlab\/embedded\/lib\/libjemalloc.so'
      end
    end

    context 'when relative URL is enabled' do
      before do
        stub_gitlab_rb(gitlab_rails: { gitlab_relative_url: '/gitlab' })
      end

      it_behaves_like "enabled gitlab-rails env", "RAILS_RELATIVE_URL_ROOT", '/gitlab'
    end

    context 'when relative URL is specified in external_url' do
      before do
        stub_gitlab_rb(external_url: 'http://localhost/gitlab')
      end

      it_behaves_like "enabled gitlab-rails env", "RAILS_RELATIVE_URL_ROOT", '/gitlab'
    end

    context 'when jemalloc is disabled' do
      before do
        stub_gitlab_rb(gitlab_rails: { enable_jemalloc: false })
      end

      it_behaves_like "disabled gitlab-rails env", "LD_PRELOAD", '\/opt\/gitlab\/embedded\/lib\/libjemalloc.so'
    end
  end

  describe "with symlinked templates" do
    let(:chef_run) { ChefSpec::SoloRunner.new(step_into: %w(templatesymlink)).converge('gitlab::default') }

    before do
      %w(
        gitlab-monitor
        gitlab-workhorse
        logrotate
        nginx
        node-exporter
        postgres-exporter
        postgresql
        prometheus
        redis
        redis-exporter
        sidekiq
        unicorn
        gitaly
      ).map { |svc| stub_should_notify?(svc, true) }
    end

    describe 'database.yml' do
      let(:templatesymlink_template) { chef_run.template('/var/opt/gitlab/gitlab-rails/etc/database.yml') }
      let(:templatesymlink_link) { chef_run.link("Link /opt/gitlab/embedded/service/gitlab-rails/config/database.yml to /var/opt/gitlab/gitlab-rails/etc/database.yml") }

      context 'by default' do
        cached(:chef_run) do
          ChefSpec::SoloRunner.new(step_into: %w(templatesymlink)).converge('gitlab::default')
        end

        it 'creates the template' do
          expect(chef_run).to create_template('/var/opt/gitlab/gitlab-rails/etc/database.yml')
            .with(
              owner: 'root',
              group: 'root',
              mode: '0644'
            )
          expect(chef_run).to render_file('/var/opt/gitlab/gitlab-rails/etc/database.yml').with_content(/host: \"\/var\/opt\/gitlab\/postgresql\"/)
          expect(chef_run).to render_file('/var/opt/gitlab/gitlab-rails/etc/database.yml').with_content(/database: gitlabhq_production/)
          expect(chef_run).to render_file('/var/opt/gitlab/gitlab-rails/etc/database.yml').with_content(/load_balancing: {"hosts":\[\]}/)
          expect(chef_run).to render_file('/var/opt/gitlab/gitlab-rails/etc/database.yml').with_content(/prepared_statements: true/)
          expect(chef_run).to render_file('/var/opt/gitlab/gitlab-rails/etc/database.yml').with_content(/statements_limit: 1000/)
        end

        it 'template triggers notifications' do
          expect(templatesymlink_template).to notify('service[unicorn]').to(:restart).delayed
          expect(templatesymlink_template).to notify('service[sidekiq]').to(:restart).delayed
          expect(templatesymlink_template).not_to notify('service[gitlab-workhorse]').to(:restart).delayed
          expect(templatesymlink_template).not_to notify('service[nginx]').to(:restart).delayed
        end

        it 'creates the symlink' do
          expect(chef_run).to create_link("Link /opt/gitlab/embedded/service/gitlab-rails/config/database.yml to /var/opt/gitlab/gitlab-rails/etc/database.yml")
        end

        it 'linking triggers notifications' do
          expect(templatesymlink_link).to notify('service[unicorn]').to(:restart).delayed
          expect(templatesymlink_link).to notify('service[sidekiq]').to(:restart).delayed
          expect(templatesymlink_link).not_to notify('service[gitlab-workhorse]').to(:restart).delayed
          expect(templatesymlink_link).not_to notify('service[nginx]').to(:restart).delayed
        end
      end

      context 'with specific database settings' do
        context 'when multiple postgresql listen_address is used' do
          before do
            stub_gitlab_rb(postgresql: { listen_address: "127.0.0.1,1.1.1.1" })
          end

          it 'creates the postgres configuration file with multi listen_address and database.yml file with one host' do
            expect(chef_run).to render_file('/var/opt/gitlab/gitlab-rails/etc/database.yml').with_content(/host: "127.0.0.1"/)
            expect(chef_run).to render_file('/var/opt/gitlab/postgresql/data/postgresql.conf').with_content(/listen_addresses = '127.0.0.1,1.1.1.1'/)
          end
        end

        context 'when no postgresql listen_address is used' do
          it 'creates the postgres configuration file with empty listen_address and database.yml file with default one' do
            expect(chef_run).to render_file('/var/opt/gitlab/gitlab-rails/etc/database.yml').with_content(/host: "\/var\/opt\/gitlab\/postgresql"/)
            expect(chef_run).to render_file('/var/opt/gitlab/postgresql/data/postgresql.conf').with_content(/listen_addresses = ''/)
          end
        end

        context 'when one postgresql listen_address is used' do
          cached(:chef_run) do
            RSpec::Mocks.with_temporary_scope do
              stub_gitlab_rb(postgresql: { listen_address: "127.0.0.1" })
            end

            ChefSpec::SoloRunner.new(step_into: %w(templatesymlink)).converge('gitlab::default')
          end

          it 'creates the postgres configuration file with one listen_address and database.yml file with one host' do
            expect(chef_run).to render_file('/var/opt/gitlab/gitlab-rails/etc/database.yml').with_content(/host: "127.0.0.1"/)
            expect(chef_run).to render_file('/var/opt/gitlab/postgresql/data/postgresql.conf').with_content(/listen_addresses = '127.0.0.1'/)
          end

          it 'template triggers notifications' do
            expect(templatesymlink_template).to notify('service[unicorn]').to(:restart).delayed
            expect(templatesymlink_template).to notify('service[sidekiq]').to(:restart).delayed
            expect(templatesymlink_template).not_to notify('service[gitlab-workhorse]').to(:restart).delayed
            expect(templatesymlink_template).not_to notify('service[nginx]').to(:restart).delayed
          end

          it 'creates the symlink' do
            expect(chef_run).to create_link("Link /opt/gitlab/embedded/service/gitlab-rails/config/database.yml to /var/opt/gitlab/gitlab-rails/etc/database.yml")
          end

          it 'linking triggers notifications' do
            expect(templatesymlink_link).to notify('service[unicorn]').to(:restart).delayed
            expect(templatesymlink_link).to notify('service[sidekiq]').to(:restart).delayed
            expect(templatesymlink_link).not_to notify('service[gitlab-workhorse]').to(:restart).delayed
            expect(templatesymlink_link).not_to notify('service[nginx]').to(:restart).delayed
          end
        end

        context 'when load balancers are specified' do
          before do
            stub_gitlab_rb(gitlab_rails: { db_load_balancing: { 'hosts' => ['primary.example.com', 'secondary.example.com'] } })
          end

          it 'uses provided value in database.yml' do
            expect(chef_run).to render_file('/var/opt/gitlab/gitlab-rails/etc/database.yml').with_content(/load_balancing: {"hosts":\["primary.example.com","secondary.example.com"\]}/)
          end
        end

        context 'when prepared_statements are disabled' do
          before do
            stub_gitlab_rb(gitlab_rails: { db_prepared_statements: false })
          end

          it 'uses provided value in database.yml' do
            expect(chef_run).to render_file('/var/opt/gitlab/gitlab-rails/etc/database.yml').with_content(/prepared_statements: false/)
            expect(chef_run).to render_file('/var/opt/gitlab/gitlab-rails/etc/database.yml').with_content(/statements_limit: 1000/)
          end
        end

        context 'when limit for prepared_statements are specified' do
          before do
            stub_gitlab_rb(gitlab_rails: { db_statements_limit: 12345 })
          end

          it 'uses provided value in database.yml' do
            expect(chef_run).to render_file('/var/opt/gitlab/gitlab-rails/etc/database.yml').with_content(/statements_limit: 12345/)
            expect(chef_run).to render_file('/var/opt/gitlab/gitlab-rails/etc/database.yml').with_content(/prepared_statements: true/)
          end
        end
      end
    end

    describe 'gitlab_workhorse_secret' do
      let(:templatesymlink_template) { chef_run.template('/var/opt/gitlab/gitlab-rails/etc/gitlab_workhorse_secret') }
      let(:templatesymlink_link) { chef_run.link("Link /opt/gitlab/embedded/service/gitlab-rails/.gitlab_workhorse_secret to /var/opt/gitlab/gitlab-rails/etc/gitlab_workhorse_secret") }

      context 'by default' do
        cached(:chef_run) do
          ChefSpec::SoloRunner.new(step_into: %w(templatesymlink)).converge('gitlab::default')
        end

        it 'creates the template' do
          expect(chef_run).to create_template('/var/opt/gitlab/gitlab-rails/etc/gitlab_workhorse_secret')
            .with(
              owner: 'root',
              group: 'root',
              mode: '0644'
            )
        end

        it 'template triggers notifications' do
          expect(templatesymlink_template).to notify('service[gitlab-workhorse]').to(:restart).delayed
          expect(templatesymlink_template).to notify('service[unicorn]').to(:restart).delayed
          expect(templatesymlink_template).to notify('service[sidekiq]').to(:restart).delayed
        end

        it 'creates the symlink' do
          expect(chef_run).to create_link("Link /opt/gitlab/embedded/service/gitlab-rails/.gitlab_workhorse_secret to /var/opt/gitlab/gitlab-rails/etc/gitlab_workhorse_secret")
        end

        it 'linking triggers notifications' do
          expect(templatesymlink_link).to notify('service[gitlab-workhorse]').to(:restart).delayed
          expect(templatesymlink_link).to notify('service[unicorn]').to(:restart).delayed
          expect(templatesymlink_link).to notify('service[sidekiq]').to(:restart).delayed
        end
      end

      context 'with specific gitlab_workhorse_secret' do
        cached(:chef_run) do
          RSpec::Mocks.with_temporary_scope do
            stub_gitlab_rb(gitlab_workhorse: { secret_token: 'abc123-gitlab-workhorse' })
          end

          ChefSpec::SoloRunner.new(step_into: %w(templatesymlink)).converge('gitlab::default')
        end

        it 'renders the correct node attribute' do
          expect(chef_run).to render_file('/var/opt/gitlab/gitlab-rails/etc/gitlab_workhorse_secret')
            .with_content('abc123-gitlab-workhorse')
        end

        it 'uses the correct owner and permissions' do
          expect(chef_run).to create_template('/var/opt/gitlab/gitlab-rails/etc/gitlab_workhorse_secret')
            .with(
              owner: 'root',
              group: 'root',
              mode: '0644'
            )
        end

        it 'template triggers notifications' do
          expect(templatesymlink_template).to notify('service[gitlab-workhorse]').to(:restart).delayed
          expect(templatesymlink_template).to notify('service[unicorn]').to(:restart).delayed
          expect(templatesymlink_template).to notify('service[sidekiq]').to(:restart).delayed
        end

        it 'creates the symlink' do
          expect(chef_run).to create_link("Link /opt/gitlab/embedded/service/gitlab-rails/.gitlab_workhorse_secret to /var/opt/gitlab/gitlab-rails/etc/gitlab_workhorse_secret")
        end

        it 'linking triggers notifications' do
          expect(templatesymlink_link).to notify('service[gitlab-workhorse]').to(:restart).delayed
          expect(templatesymlink_link).to notify('service[unicorn]').to(:restart).delayed
          expect(templatesymlink_link).to notify('service[sidekiq]').to(:restart).delayed
        end
      end
    end
  end
  context 'gitlab registry' do
    describe 'registry is disabled' do
      it 'does not generate gitlab-registry.key file' do
        expect(chef_run).not_to render_file("/var/opt/gitlab/gitlab-rails/etc/gitlab-registry.key")
      end
    end

    describe 'registry is enabled' do
      before do
        stub_gitlab_rb(
          gitlab_rails: {
            registry_enabled: true
          }
        )
      end

      it 'generates gitlab-registry.key file' do
        expect(chef_run).to render_file("/var/opt/gitlab/gitlab-rails/etc/gitlab-registry.key").with_content(/\A-----BEGIN RSA PRIVATE KEY-----\n.+\n-----END RSA PRIVATE KEY-----\n\Z/m)
      end
    end
  end
end
