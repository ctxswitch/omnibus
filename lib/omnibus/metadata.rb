#
# Copyright 2014-2018 Chef Software, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

require "ffi_yajl"

module Omnibus
  class Metadata
    extend Sugarable
    include Sugarable

    class << self
      #
      # Render the metadata for the package at the given path, generated by the
      # given project.
      #
      # @raise [NoPackageFile]
      #   if the given +path+ does not contain a package
      #
      # @param [String] path
      #   the path to the package (or compressed object) on disk
      # @param [Project] project
      #   the project which generated the given package or compressed object
      #
      # @return [String]
      #   the path to the metadata on disk
      #
      def generate(path, project)
        unless File.exist?(path)
          raise NoPackageFile.new(path)
        end

        package = Package.new(path)

        data = {
          # Package
          basename: package.name,
          md5: package.md5,
          sha1: package.sha1,
          sha256: package.sha256,
          sha512: package.sha512,
          platform: platform_shortname,
          platform_version: platform_version,
          arch: arch,

          # Project
          name: project.name,
          friendly_name: project.friendly_name,
          homepage: project.homepage,
          version: project.build_version,
          iteration: project.build_iteration,
          license: project.license,
          version_manifest: project.built_manifest.to_hash,
          license_content: File.exist?(project.license_file_path) ? File.read(project.license_file_path) : "",
        }

        instance = new(package, data)
        instance.save
        instance.path
      end

      #
      # Load the metadata from disk.
      #
      # @param [Package] package
      #   the package for this metadata
      #
      # @return [Metadata]
      #
      def for_package(package)
        data = File.read(path_for(package))
        hash = FFI_Yajl::Parser.parse(data, symbolize_names: true)

        # Ensure Platform version has been truncated
        if hash[:platform_version] && hash[:platform]
          hash[:platform_version] = truncate_platform_version(hash[:platform_version], hash[:platform])
        end

        # Ensure an interation exists
        hash[:iteration] ||= 1

        new(package, hash)
      rescue Errno::ENOENT
        raise NoPackageMetadataFile.new(package.path)
      end

      #
      # The metadata path that corresponds to the package.
      #
      # @param [Package] package
      #   the package for this metadata
      #
      # @return [String]
      #
      def path_for(package)
        "#{package.path}.metadata.json"
      end

      #
      # The architecture for this machine, as reported from Ohai.
      #
      # @return [String]
      #
      def arch
        if windows? && windows_arch_i386?
          "i386"
        elsif solaris?
          if intel?
            "i386"
          elsif sparc?
            "sparc"
          end
        else
          Ohai["kernel"]["machine"]
        end
      end

      #
      # Platform version to be used in package metadata.
      #
      # @return [String]
      #   the platform version
      #
      def platform_version
        truncate_platform_version(Ohai["platform_version"], platform_shortname)
      end

      #
      # Platform name to be used when creating metadata for the artifact.
      #
      # @return [String]
      #   the platform family short name
      #
      def platform_shortname
        if rhel?
          "el"
        elsif suse?
          "sles"
        else
          Ohai["platform"]
        end
      end

      private

      #
      # On certain platforms we don't care about the full MAJOR.MINOR.PATCH platform
      # version. This method will properly truncate the version down to a more human
      # friendly version. This version can also be thought of as a 'marketing'
      # version.
      #
      # @param [String] platform_version
      #   the platform version to truncate
      # @param [String] platform
      #   the platform shortname. this might be an Ohai-returned platform or
      #   platform family but it also might be a shortname like `el`
      #
      # rubocop:disable Lint/DuplicateCaseCondition
      def truncate_platform_version(platform_version, platform)
        case platform
        when "centos", "debian", "el", "fedora", "freebsd", "omnios", "pidora", "raspbian", "rhel", "sles", "suse", "smartos"
          # Only want MAJOR (e.g. Debian 7, OmniOS r151006, SmartOS 20120809T221258Z)
          platform_version.split(".").first
        when "aix", "alpine", "mac_os_x", "openbsd", "slackware", "solaris2", "opensuse", "opensuseleap", "ubuntu", "amazon"
          # Only want MAJOR.MINOR (e.g. Mac OS X 10.9, Ubuntu 12.04)
          platform_version.split(".")[0..1].join(".")
        when "arch", "gentoo", "kali"
          # Arch Linux / Gentoo do not have a platform_version ohai attribute, they are rolling release (lsb_release -r)
          "rolling"
        when "windows"
          # Windows has this really awesome "feature", where their version numbers
          # internally do not match the "marketing" name.
          #
          # Definitively computing the Windows marketing name actually takes more
          # than the platform version. Take a look at the following file for the
          # details:
          #
          #   https://github.com/chef/chef/blob/master/lib/chef/win32/version.rb
          #
          # As we don't need to be exact here the simple mapping below is based on:
          #
          #  http://www.jrsoftware.org/ishelp/index.php?topic=winvernotes
          #
          # Microsoft's version listing (more general than the above) is here:
          #
          # https://msdn.microsoft.com/en-us/library/windows/desktop/ms724832(v=vs.85).aspx
          #
          case platform_version
          when "5.0.2195", "2000"   then "2000"
          when "5.1.2600", "xp"     then "xp"
          when "5.2.3790", "2003r2" then "2003r2"
          when "6.0.6001", "2008"   then "2008"
          when "6.1.7600", "7"      then "7"
          when "6.1.7601", "2008r2" then "2008r2"
          when "6.2.9200", "2012"   then "2012"
          # The following `when` will never match since Windows 8's platform
          # version is the same as Windows 2012. It's only here for completeness and
          # documentation.
          when "6.2.9200", "8"      then "8"
          when /6\.3\.\d+/, "2012r2" then "2012r2"
          # The following `when` will never match since Windows 8.1's platform
          # version is the same as Windows 2012R2. It's only here for completeness
          # and documentation.
          when /6\.3\.\d+/, "8.1" then "8.1"
          when /^10\.0/ then "10"
          else
            raise UnknownPlatformVersion.new(platform, platform_version)
          end
        else
          raise UnknownPlatform.new(platform)
        end
      end
    end

    #
    # Create a new metadata object for the given package and hash data.
    #
    # @param [Package] package
    #   the package for this metadata
    # @param [Hash] data
    #   the hash of attributes to set in the metadata
    #
    def initialize(package, data = {})
      @package = package
      @data    = data.dup.freeze
    end

    #
    # Helper for accessing the information inside the metadata hash.
    #
    # @return [Object]
    #
    def [](key)
      @data[key]
    end

    #
    # The name of this metadata file.
    #
    # @return [String]
    #
    def name
      @name ||= File.basename(path)
    end

    #
    # @see (Metadata.path_for)
    #
    def path
      @path ||= self.class.path_for(@package)
    end

    #
    # Save the file to disk.
    #
    # @return [true]
    #
    def save
      File.open(path, "w+") do |f|
        f.write(FFI_Yajl::Encoder.encode(to_hash, pretty: true))
      end

      true
    end

    #
    # Hash representation of this metadata.
    #
    # @return [Hash]
    #
    def to_hash
      @data.dup
    end

    #
    # The JSON representation of this metadata.
    #
    # @return [String]
    #
    def to_json
      FFI_Yajl::Encoder.encode(@data, pretty: true)
    end
  end
end
