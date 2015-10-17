require 'spec_helper'

module Bosh::Director
  describe Bosh::Director::DiskManager do

    subject(:disk_manager) { DiskManager.new(cloud, logger) }
    let(:vm_recreator) { instance_double(VmRecreator) }

    let(:cloud) { instance_double(Bosh::Cloud) }
    let(:instance_plan) { DeploymentPlan::InstancePlan.new({
        existing_instance: instance_model,
        desired_instance: DeploymentPlan::DesiredInstance.new,
        instance: instance,
        network_plans: [],
      }) }

    let(:job_persistent_disk_size) { 1024 }
    let(:job) do
      job = DeploymentPlan::Job.new(logger)
      job.name = 'job-name'
      job.persistent_disk_type = DeploymentPlan::DiskType.new('disk-name', job_persistent_disk_size, {'cloud' => 'properties'})
      job
    end
    let(:instance) { DeploymentPlan::Instance.new(job, 1, 'started', nil, instance_state, nil, false, logger) }
    let(:instance_model) do
      instance = Models::Instance.make(vm: vm_model)
      instance.add_persistent_disk(persistent_disk) if persistent_disk
      instance
    end

    let(:vm_model) { Models::Vm.make(cid: 'vm234') }
    let(:persistent_disk) { Models::PersistentDisk.make(disk_cid: 'disk123', size: 2048, cloud_properties: {'cloud' => 'properties'}, active: true) }
    let(:agent_client) { instance_double(Bosh::Director::AgentClient) }
    let(:instance_state) { {'persistent_disk' => 1} }

    before do
      instance.bind_existing_instance_model(instance_model)
      allow(AgentClient).to receive(:with_vm).with(vm_model).and_return(agent_client)
      allow(agent_client).to receive(:list_disk).and_return(['disk123'])
      allow(cloud).to receive(:create_disk).and_return('new-disk-cid')
      allow(cloud).to receive(:attach_disk)
      allow(agent_client).to receive(:mount_disk)
      allow(agent_client).to receive(:migrate_disk)
      allow(agent_client).to receive(:unmount_disk)
      allow(cloud).to receive(:detach_disk)
      allow(Config).to receive(:cloud).and_return(cloud)
    end

    describe '#update_persistent_disk' do
      context 'when the disk is not currently attached' do
        let(:instance_state) { {'persistent_disk' => 0} }
        it 'attaches the disk' do
          expect(cloud).to receive(:attach_disk).with('vm234', 'disk123')
          expect(agent_client).to receive(:mount_disk).with('disk123')
          disk_manager.update_persistent_disk(instance_plan, vm_recreator)
        end
      end

      context 'checking persistent disk' do
        context 'when the agent reports a different disk cid from the model' do
          before do
            allow(agent_client).to receive(:list_disk).and_return(['random-disk-cid'])
          end

          it 'raises' do
            expect {
              disk_manager.update_persistent_disk(instance_plan, vm_recreator)
            }.to raise_error AgentDiskOutOfSync, "`job-name/1' has invalid disks: agent reports `random-disk-cid' while director record shows `disk123'"
          end
        end

        context 'when the agent reports a disk cid consistent with the model' do
          let(:inactive_disk) { Models::PersistentDisk.make(disk_cid: 'inactive-disk', active: false) }
          before { instance_model.add_persistent_disk(inactive_disk) }

          it 'logs when the disks are inactive' do
            expect(logger).to receive(:warn).with("`job-name/1' has inactive disk inactive-disk")
            disk_manager.update_persistent_disk(instance_plan, vm_recreator)
          end

          context 'when the persistent disk is changed' do
            before { expect(instance_plan.persistent_disk_changed?).to be_truthy }

            context 'when the job has persistent disk type and the disk type is non zero' do
              it 'calls to the cpi to create the disk specified by the job' do
                expect(cloud).to receive(:create_disk).with(1024, {'cloud' => 'properties'}, 'vm234').and_return('new-disk-cid')
                disk_manager.update_persistent_disk(instance_plan, vm_recreator)
              end

              it 'creates a persistent disk record' do
                disk_manager.update_persistent_disk(instance_plan, vm_recreator)
                model = Models::PersistentDisk.where(instance_id: instance_model.id, size: 1024).first
                expect(model.cloud_properties).to eq({'cloud' => 'properties'})
              end

              it 'attaches the disk to the vm' do
                expect(cloud).to receive(:attach_disk).with('vm234', 'new-disk-cid')
                disk_manager.update_persistent_disk(instance_plan, vm_recreator)
              end

              context 'when the disk fails to attach with no disk space error' do
                let(:no_space) { Bosh::Clouds::NoDiskSpace.new(ok_to_retry) }

                before do
                  expect(cloud).to receive(:attach_disk).with('vm234', 'new-disk-cid').once.and_raise(no_space)
                end

                context 'when it is ok to retry' do
                  let(:ok_to_retry) { true }

                  before { allow(vm_recreator).to receive(:recreate_vm) }

                  it 'recreates the vm' do
                    expect(cloud).to receive(:attach_disk).with('vm234', 'new-disk-cid').once
                    expect(vm_recreator).to receive(:recreate_vm).with(instance_plan, 'new-disk-cid')
                    disk_manager.update_persistent_disk(instance_plan, vm_recreator)
                  end

                  it 'attaches the disk' do
                    expect(cloud).to receive(:attach_disk).with('vm234', 'new-disk-cid').once
                    disk_manager.update_persistent_disk(instance_plan, vm_recreator)
                  end

                  context 'and it fails to attach the disk the second time' do
                    let(:nope) { StandardError.new('still nope') }

                    before do
                      expect(cloud).to receive(:attach_disk).with('vm234', 'new-disk-cid').once.and_raise(nope)
                    end

                    it 'deletes the unused disk and re-raises the exception from the second attempt' do
                      expect {
                        disk_manager.update_persistent_disk(instance_plan, vm_recreator)
                      }.to raise_error nope
                      expect(Models::PersistentDisk.where(:disk_cid => 'new-disk-cid').all).to eq([])
                    end
                  end
                end

                context 'when it is not ok to retry' do
                  let(:ok_to_retry) { false }

                  it 'deletes the disk and raises' do
                    expect {
                      disk_manager.update_persistent_disk(instance_plan, vm_recreator)
                    }.to raise_error no_space
                    expect(Models::PersistentDisk.where(:disk_cid => 'new-disk-cid').all).to eq([])
                  end
                end
              end

              it 'mounts the new disk' do
                expect(agent_client).to receive(:mount_disk).with('new-disk-cid')
                disk_manager.update_persistent_disk(instance_plan, vm_recreator)
              end

              context 'where there is an old disk to migrate' do
                it 'migrates the disk' do
                  expect(agent_client).to receive(:migrate_disk).with('disk123', 'new-disk-cid')
                  disk_manager.update_persistent_disk(instance_plan, vm_recreator)
                end
              end

              context 'when there is no old disk to migrate' do
                let(:persistent_disk) { nil }
                it 'does not attempt to migrate the disk' do
                  expect(agent_client).to_not receive(:migrate_disk)
                end
              end

              context 'mounting and migrating to the new disk' do
                let(:disk_error) { StandardError.new }

                context 'when mounting and migrating disks succeeds' do
                  before do
                    allow(cloud).to receive(:detach_disk).with('vm234', 'new-disk-cid')
                    allow(agent_client).to receive(:list_disk).and_return(['disk123', 'new-disk-cid'])
                  end

                  it 'switches active disks' do
                    disk_manager.update_persistent_disk(instance_plan, vm_recreator)
                    expect(Models::PersistentDisk.where(instance_id: instance_model.id, disk_cid: 'new-disk-cid', active: true).first).to_not be_nil
                  end

                  context 'when switching active disk succeeds' do
                    let(:snapshot) { Models::Snapshot.make }
                    before do
                      persistent_disk.add_snapshot(snapshot)
                    end

                    it 'deletes the old mounted disk' do
                      expect(agent_client).to receive(:unmount_disk).with('disk123')
                      expect(cloud).to receive(:detach_disk).with('vm234', 'disk123')

                      disk_manager.update_persistent_disk(instance_plan, vm_recreator)

                      expect(Models::PersistentDisk.where(disk_cid: 'disk123').first).to be_nil
                    end
                  end
                end

                context 'when mounting the disk raises' do
                  before do
                    allow(agent_client).to receive(:list_disk).and_return(['disk123'])
                    expect(agent_client).to receive(:mount_disk).with('new-disk-cid').and_raise(disk_error)
                  end

                  it 'deletes the disk and re-raises the error' do
                    expect(agent_client).to_not receive(:unmount_disk)
                    expect(cloud).to receive(:detach_disk).with('vm234', 'new-disk-cid')
                    expect {
                      disk_manager.update_persistent_disk(instance_plan, vm_recreator)
                    }.to raise_error disk_error
                    expect(Models::PersistentDisk.where(disk_cid: 'new-disk-cid').all).to eq([])
                  end
                end

                context 'when migrating the disk raises' do
                  before do
                    allow(agent_client).to receive(:list_disk).and_return(['disk123', 'new-disk-cid'])
                    allow(agent_client).to receive(:mount_disk).with('new-disk-cid')
                    expect(agent_client).to receive(:migrate_disk).with('disk123', 'new-disk-cid').and_raise(disk_error)
                  end

                  it 'deletes the disk and re-raises the error' do
                    expect(agent_client).to receive(:unmount_disk).with('new-disk-cid')
                    expect(cloud).to receive(:detach_disk).with('vm234', 'new-disk-cid')
                    expect {
                      disk_manager.update_persistent_disk(instance_plan, vm_recreator)
                    }.to raise_error disk_error
                    expect(Models::PersistentDisk.where(disk_cid: 'new-disk-cid').all).to eq([])
                  end
                end
              end
            end
          end

          context 'when the persistent disk has not changed' do
            let(:job_persistent_disk_size) { 2048 }

            before do
              expect(instance_plan.persistent_disk_changed?).to_not be_truthy
            end

            it 'does not migrate the disk' do
              expect(cloud).to_not receive(:create_disk)
              disk_manager.update_persistent_disk(instance_plan, nil)
            end
          end
        end
      end
    end

    describe '#delete_persistent_disks' do
      let(:snapshot) { Models::Snapshot.make(persistent_disk: persistent_disk) }
      before { persistent_disk.add_snapshot(snapshot) }

      it 'deletes snapshots' do
        expect(Models::Snapshot.all.size).to eq(1)
        disk_manager.delete_persistent_disks(instance_model)
        expect(Models::Snapshot.all.size).to eq(0)
      end

      it 'deletes disks for instance' do
        expect(Models::PersistentDisk.all.size).to eq(1)
        disk_manager.delete_persistent_disks(instance_model)
        expect(Models::PersistentDisk.all.size).to eq(0)
      end

      it 'does not delete disk and snapshots from cloud' do
        expect(cloud).to_not receive(:delete_snapshot)
        expect(cloud).to_not receive(:delete_disk)

        disk_manager.delete_persistent_disks(instance_model)
      end
    end

    describe '#orphan_disk' do
      it 'orphans disks and snapshots' do
        snapshot = Models::Snapshot.make(persistent_disk: persistent_disk)

        disk_manager.orphan_disk(persistent_disk)
        orphan_disk = Models::OrphanDisk.first
        orphan_snapshot = Models::OrphanSnapshot.first

        expect(orphan_disk.disk_cid).to eq(persistent_disk.disk_cid)
        expect(orphan_snapshot.snapshot_cid).to eq(snapshot.snapshot_cid)
        expect(orphan_snapshot.orphan_disk).to eq(orphan_disk)

        expect(Models::PersistentDisk.all.count).to eq(0)
        expect(Models::Snapshot.all.count).to eq(0)
      end

      it 'should transactionally move orphan disks and snapshots' do
        conflicting_orphan_disk = Models::OrphanDisk.make
        conflicting_orphan_snapshot = Models::OrphanSnapshot.make(
          orphan_disk: conflicting_orphan_disk,
          snapshot_cid: 'existing_cid',
          created_at: 0
        )

        snapshot = Models::Snapshot.make(
          snapshot_cid: 'existing_cid',
          persistent_disk: persistent_disk
        )

        expect { disk_manager.orphan_disk(persistent_disk) }.to raise_error(Sequel::ValidationFailed)

        conflicting_orphan_snapshot.destroy
        conflicting_orphan_disk.destroy

        expect(Models::PersistentDisk.all.count).to eq(1)
        expect(Models::Snapshot.all.count).to eq(1)
        expect(Models::OrphanDisk.all.count).to eq(0)
        expect(Models::OrphanSnapshot.all.count).to eq(0)
      end
    end

    describe '#list_orphan_disk' do

      it 'returns an array of orphaned disks as hashes' do
        orphaned_at = Time.now
        other_orphaned_at = Time.now
        Models::OrphanDisk.make(
          disk_cid: 'random-disk-cid-1',
          instance_name: 'fake-name-1',
          size: 10,
          deployment_name: 'fake-deployment',
          orphaned_at: orphaned_at,
        )
        Models::OrphanDisk.make(
          disk_cid: 'random-disk-cid-2',
          instance_name: 'fake-name-2',
          availability_zone: 'az2',
          deployment_name: 'fake-deployment',
          orphaned_at: other_orphaned_at,
          cloud_properties: {'cloud' => 'properties'}
        )

        expect(subject.list_orphan_disks).to eq([
              {
                'disk_cid' => 'random-disk-cid-1',
                'size' => 10,
                'availability_zone' => 'n/a',
                'deployment_name' => 'fake-deployment',
                'instance_name' => 'fake-name-1',
                'cloud_properties' => 'n/a',
                'orphaned_at' => orphaned_at.to_s
              },
              {
                'disk_cid' => 'random-disk-cid-2',
                'size' => 'n/a',
                'availability_zone' => 'az2',
                'deployment_name' => 'fake-deployment',
                'instance_name' => 'fake-name-2',
                'cloud_properties' => {'cloud' => 'properties'},
                'orphaned_at' => other_orphaned_at.to_s
              }
            ])
      end
    end

    describe '#delete_orphan_disks' do
      let(:orphan_disk_cid_1) { Models::OrphanDisk.make.disk_cid }
      let(:orphan_disk_cid_2) { Models::OrphanDisk.make.disk_cid }

      it 'deletes disks from the cloud' do
        expect(cloud).to receive(:delete_disk).with(orphan_disk_cid_1)

        subject.delete_orphan_disk(orphan_disk_cid_1)

        expect(Models::OrphanDisk.where(disk_cid: orphan_disk_cid_1).all).to be_empty
        expect(Models::OrphanDisk.where(disk_cid: orphan_disk_cid_2).all).to_not be_empty
      end

      context 'when disk is not found in the cloud' do
        it 'continues to delete the remaining disks' do
          allow(cloud).to receive(:delete_disk).with(orphan_disk_cid_1).and_raise(Bosh::Clouds::DiskNotFound.new(false))

          subject.delete_orphan_disk(orphan_disk_cid_1)

          expect(Models::OrphanDisk.where(disk_cid: orphan_disk_cid_1).all).to be_empty
        end
      end

    end
  end
end
