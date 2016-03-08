require 'spec_helper'
require 'yaml'

module Bosh::Director
  describe DependencyKeyGenerator do

    let(:key_generator) { DependencyKeyGenerator.new }

    context 'when generating from compiled packages key from the release manifest' do
      context 'when compiled package has no dependencies' do
        let(:compiled_packages) { [] }

        xit 'should generate a dependency key' do
          key = key_generator.generate_from_manifest('bad-package', compiled_packages)
          expect(key).to eq '[]'
        end
      end

      context 'when compiled package has no dependencies' do
        let(:compiled_packages) do
          [
            {
              'name' => 'fake-pkg0',
              'version' => 'fake-pkg0-version',
              'fingerprint' => 'fake-pkg0-fingerprint',
              'stemcell' => 'ubuntu-trusty/3000',
              'dependencies' => []
            },
            {
              'name' => 'fake-pkg2',
              'version' => 'fake-pkg2-version',
              'fingerprint' => 'fake-pkg2-fingerprint',
              'stemcell' => 'ubuntu-trusty/3000',
              'dependencies' => []
            },
          ]
        end

        it 'should generate a dependency key' do
          key = key_generator.generate_from_manifest('fake-pkg0', compiled_packages)
          expect(key).to eq('[]')
        end
      end

      context 'when compiled package has more than 1 level deep transitive dependencies' do
        let(:compiled_packages) do
          [
            {
              'name' => 'fake-pkg0',
              'version' => 'fake-pkg0-version',
              'fingerprint' => 'fake-pkg0-fingerprint',
              'stemcell' => 'ubuntu-trusty/3000',
              'dependencies' => ['fake-pkg2']
            },
            {
              'name' => 'fake-pkg1',
              'version' => 'fake-pkg1-version',
              'fingerprint' => 'fake-pkg1-fingerprint',
              'stemcell' => 'ubuntu-trusty/3000',
              'dependencies' => []
            },
            {
              'name' => 'fake-pkg2',
              'version' => 'fake-pkg2-version',
              'fingerprint' => 'fake-pkg2-fingerprint',
              'stemcell' => 'ubuntu-trusty/3000',
              'dependencies' => ['fake-pkg3']
            },
            {
              'name' => 'fake-pkg3',
              'version' => 'fake-pkg3-version',
              'fingerprint' => 'fake-pkg3-fingerprint',
              'stemcell' => 'ubuntu-trusty/3000',
              'dependencies' => []
            },
          ]
        end

        it 'should generate a dependency key' do
          key = key_generator.generate_from_manifest('fake-pkg0', compiled_packages)
          expect(key).to eq('[["fake-pkg2","fake-pkg2-version",[["fake-pkg3","fake-pkg3-version"]]]]')

          key = key_generator.generate_from_manifest('fake-pkg2', compiled_packages)
          expect(key).to eq('[["fake-pkg3","fake-pkg3-version"]]')
        end
      end

      context 'when compiled package has 1-level deep transitive dependencies' do
        let(:compiled_packages) do
          [
            {
              'name' => 'fake-pkg1',
              'version' => 'fake-pkg1-version',
              'fingerprint' => 'fake-pkg1-fingerprint',
              'stemcell' => 'ubuntu-trusty/3000',
              'dependencies' => ['fake-pkg2', 'fake-pkg3']
            },
            {
              'name' => 'fake-pkg2',
              'version' => 'fake-pkg2-version',
              'fingerprint' => 'fake-pkg2-fingerprint',
              'stemcell' => 'ubuntu-trusty/3000',
              'dependencies' => []
            },
            {
              'name' => 'fake-pkg3',
              'version' => 'fake-pkg3-version',
              'fingerprint' => 'fake-pkg3-fingerprint',
              'stemcell' => 'ubuntu-trusty/3000',
              'dependencies' => []
            },
          ]
        end

        it 'should generate a dependency key' do
          key = key_generator.generate_from_manifest('fake-pkg1', compiled_packages)
          expect(key).to eq('[["fake-pkg2","fake-pkg2-version"],["fake-pkg3","fake-pkg3-version"]]')
        end
      end
    end


    context 'when generating from Models::Package' do
      let(:release) { Models::Release.make(name: 'release-1') }
      let(:release_version) do
        Models::ReleaseVersion.make(release: release)
      end

      context 'when package has no dependencies' do
        let(:package) do
          Models::Package.make(name: 'pkg-1', version: '1.1', release: release)
        end

        before do
          release_version.packages << package
        end

        it 'should generate a dependency key' do
          expect(key_generator.generate_from_models(package, release_version)).to eq('[]')
        end
      end

      context 'when package has 1-level deep transitive dependencies' do
        context 'there is a single release version for a release' do
          let(:package) do
            Models::Package.make(name: 'pkg-1', version: '1.1', release: release, dependency_set_json: ['pkg-2', 'pkg-3'].to_json)
          end

          before do
            package_2 = Models::Package.make(name: 'pkg-2', version: '1.4', release: release)
            package_3 = Models::Package.make(name: 'pkg-3', version: '1.7', release: release)

            [package, package_2, package_3].each { |p| release_version.packages << p }
          end

          it 'should generate a dependency key' do
            expect(key_generator.generate_from_models(package, release_version)).to eq('[["pkg-2","1.4"],["pkg-3","1.7"]]')
          end
        end

        context 'there are multiple release versions for the same release' do
          let(:package) do
            Models::Package.make(name: 'pkg-1', version: '1.1', release: release, dependency_set_json: ['pkg-2', 'pkg-3'].to_json)
          end

          let(:release_version_2) do
            Models::ReleaseVersion.make(release: release, version: 'favourite-version')
          end

          before do
            package_2 = Models::Package.make(name: 'pkg-2', version: '1.4', release: release)
            new_package_2 = Models::Package.make(name: 'pkg-2', version: '1.5', release: release)
            package_3 = Models::Package.make(name: 'pkg-3', version: '1.7', release: release)
            new_package_3 = Models::Package.make(name: 'pkg-3', version: '1.8', release: release)

            [package, package_2, package_3].each { |p| release_version.packages << p }
            [package, new_package_2, new_package_3].each { |p| release_version_2.packages << p }
          end

          it 'should generate a dependency key specific to the release version' do
            expect(key_generator.generate_from_models(package, release_version_2)).to eq('[["pkg-2","1.5"],["pkg-3","1.8"]]')
          end
        end

        context 'there multiple releases using the same packages' do
          let(:new_release) { Models::Release.make(name: 'new-release')}

          let(:package) do
            Models::Package.make(name: 'pkg-1', version: '1.1', release: new_release, dependency_set_json: ['pkg-2'].to_json)
          end

          let(:new_release_version) do
            Models::ReleaseVersion.make(release: new_release, version: 'favourite-version')
          end

          before do
            Models::Package.make(name: 'pkg-1', version: '1.1', release: release, dependency_set_json: ['pkg-2', 'pkg-3'].to_json)

            package_2 = Models::Package.make(name: 'pkg-2', version: '1.4', release: release)
            new_package_2 = Models::Package.make(name: 'pkg-2', version: '1.5', release: new_release)
            package_3 = Models::Package.make(name: 'pkg-3', version: '1.7', release: release)

            [package, package_2, package_3].each { |p| release_version.packages << p }
            [package, new_package_2].each { |p| new_release_version.packages << p }
          end

          it 'should generate a dependency key specific to the release version' do
            expect(key_generator.generate_from_models(package, new_release_version)).to eq('[["pkg-2","1.5"]]')
          end
        end
      end

      context 'when package model has more than 1 level deep transitive dependencies' do
        context 'there is a single release version for a release' do
          let(:package) do
            Models::Package.make(name: 'pkg-1', version: '1.1', release: release, dependency_set_json: ['pkg-2', 'pkg-3'].to_json)
          end

          before do
            package_2 = Models::Package.make(name: 'pkg-2', version: '1.4', release: release, dependency_set_json: ['pkg-4'])
            package_3 = Models::Package.make(name: 'pkg-3', version: '1.7', release: release)
            package_4 = Models::Package.make(name: 'pkg-4', version: '3.7', release: release)

            [package, package_2, package_3, package_4].each { |p| release_version.packages << p }
          end

          xit 'should generate a dependency key' do
            expect(key_generator.generate_from_models(package, release_version)).to eq('[["pkg-2","1.4",[["pkg-4","3.7"]]],["pkg-3","1.7"]]')
          end
        end
      end
    end
  end
end


