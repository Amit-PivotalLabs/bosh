module Bosh::Cli
  class ArchiveBuilder
    attr_reader :options

    def initialize(archive_repository_provider, options = {})
      @archive_repository_provider = archive_repository_provider
      @options = options
    end

    def build(resource)
      @archive_repository = @archive_repository_provider.get(resource)
      resource.run_script(:prepare)

      artifact = nil
      with_indent('  ') do
        artifact = locate_artifact(resource)
        if artifact.nil?
          artifact = create_artifact(resource)
          say("Generated version #{artifact.fingerprint}".make_green)

          unless dry_run?
            artifact = @archive_repository.install(artifact)
          end
        end

        if final? && !dry_run?
          say("Uploading final version '#{artifact.version}'...")
          artifact = @archive_repository.upload_to_blobstore(artifact)
          say("Uploaded, blobstore id '#{artifact.metadata['blobstore_id']}'")
        end
      end

      artifact
    rescue Bosh::Blobstore::BlobstoreError => e
      raise BlobstoreError, "Blobstore error: #{e}"
    end

    def dry_run?
      !!options[:dry_run]
    end

    def final?
      !!options[:final]
    end

    private

    def copy_files(resource)
      resource.files.each do |src, dest|
        dest_path = Pathname(staging_dir).join(dest)
        if File.directory?(src)
          FileUtils.mkdir_p(dest_path)
        else
          FileUtils.mkdir_p(dest_path.parent)
          FileUtils.cp(src, dest_path, :preserve => true)
        end
      end
    end

    def locate_artifact(resource)
      artifact = @archive_repository.lookup(resource)

      if artifact.nil?
        say("No artifact found for #{resource.name}".make_red)
        return nil
      end

      say("Found #{artifact.dev_artifact? ? 'dev' : 'final'} artifact for #{artifact.name}")

      if artifact.dev_artifact? && final? && !dry_run?
        artifact = @archive_repository.copy_from_dev_to_final(artifact)
      end

      artifact
    rescue Bosh::Cli::CorruptedArchive => e
      say "#{"Warning".make_red}: #{e.message}"
      nil
    end

    def create_artifact(resource)
      tarball_path = safe_temp_file(resource.name, '.tgz')

      say('Generating...')

      copy_files(resource)
      resource.run_script(:pre_packaging, staging_dir)

      in_staging_dir do
        tar_out = `tar -chzf #{tarball_path} . 2>&1`
        unless $?.exitstatus == 0
          raise PackagingError, "Cannot create tarball: #{tar_out}"
        end
      end

      fingerprint = BuildArtifact.make_fingerprint(resource)

      metadata = resource.metadata.merge(
        'notes' => ['new version'],
        'new_version' => true,
      )

      sha1 = BuildArtifact.checksum(tarball_path)
      BuildArtifact.new(resource.name, metadata, fingerprint, tarball_path, sha1, resource.dependencies, !final?)
    end

    def file_checksum(path)
      Digest::SHA1.file(path).hexdigest
    end

    def staging_dir
      @staging_dir ||= Dir.mktmpdir
    end

    def in_staging_dir
      Dir.chdir(staging_dir) { yield }
    end

    private

    def safe_temp_file(prefix, suffix, dir = Dir.tmpdir)
      Dir::Tmpname.create([prefix, suffix], dir) do |tmpname, _, _|
        File.open(tmpname, File::RDWR|File::CREAT|File::EXCL).close
      end
    end
  end
end
