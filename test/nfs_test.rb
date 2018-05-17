#! /usr/bin/env rspec
# Copyright (c) 2014 SUSE Linux.
#  All Rights Reserved.

#  This program is free software; you can redistribute it and/or
#  modify it under the terms of version 2 or 3 of the GNU General
#  Public License as published by the Free Software Foundation.

#  This program is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.   See the
#  GNU General Public License for more details.

#  You should have received a copy of the GNU General Public License
#  along with this program; if not, contact SUSE LLC.

#  To contact SUSE about this file by physical or electronic mail,
#  you may find current contact information at www.suse.com

require_relative "spec_helper"
require "yaml"
require "y2firewall/firewalld"

Yast.import "Nfs"
Yast.import "Progress"
Yast.import "Service"

describe "Yast::Nfs" do
  subject { Yast::Nfs }
  let(:firewalld) { Y2Firewall::Firewalld.instance }
  let(:fstab_entries) { YAML.load_file(File.join(DATA_PATH, "fstab_entries.yaml")) }
  let(:nfs_entries) { fstab_entries.select { |e| e["vfstype"] == "nfs" } }


  describe ".Import" do
    let(:profile) do
      {
        "nfs_entries" => [
          {
            "server_path" => "data.example.com:/mirror",
            "mount_point" => "/mirror",
            "nfs_options" => "defaults"
          }
        ]
      }
    end
    it "imports the nfs entries defined in the profile" do
      subject.Import(profile)
      expect(subject.nfs_entries.size).to eql(1)
    end
  end


  describe ".Read" do
    let(:fstab_entries) { YAML.load_file(File.join(DATA_PATH, "fstab_entries.yaml")) }
    let(:nfs_entries) { fstab_entries.select { |e| e["vfstype"] == "nfs" } }
    before do
      subject.skip_fstab = true
      subject.nfs4_enabled = true
      subject.nfs_gss_enabled = true
      allow(subject).to receive(:ReadNfs4)
      allow(subject).to receive(:ReadNfsGss)
      allow(subject).to receive(:ReadIdmapd)
      allow(subject).to receive(:FindPortmapper).and_return("rpcbind")
      allow(subject).to receive(:firewalld).and_return(firewalld)
      allow(firewalld).to receive(:read)
      allow(subject).to receive(:check_and_install_required_packages)
    end

    context "when the read of fstab is not set to be skipped" do
      before do
        subject.skip_fstab = false
        allow(subject).to receive(:storage_probe).and_return(true)
        allow(subject).to receive(:storage_nfs_mounts).and_return([])
      end

      it "triggers a storage reprobing returning false if fails" do
        expect(subject).to receive(:storage_probe).and_return(false)
        expect(subject.Read()).to eql(false)
      end

      it "loads the nfs entries with the information provided by the storage layer" do
        expect(subject).to receive(:load_nfs_entries).with([])
        subject.Read
      end
    end

    it "reads if nfs4 is supported in sysconfig" do
      expect(subject).to receive(:ReadNfs4).and_return(false)
      expect(subject.nfs4_enabled).to eql(true)
      subject.Read
      expect(subject.nfs4_enabled).to eql(false)
    end

    it "reads if nfs gss security is enabled in sysconfig" do
      expect(subject).to receive(:ReadNfsGss).and_return(false)
      expect(subject.nfs_gss_enabled).to eql(true)
      subject.Read
      expect(subject.nfs_gss_enabled).to eql(false)
    end

    it "checks which is the portmapper in use" do
      expect(subject).to receive(:FindPortmapper)
      subject.Read
    end

    it "reads the firewalld configuration" do
      expect(firewalld).to receive(:read)
      subject.Read
    end

    it "checks and/or install required nfs-client packages" do
      expect(subject).to receive(:check_and_install_required_packages)
      subject.Read
    end
  end

  describe ".WriteOnly" do
    before do
      # Set some sane defaults
      subject.nfs4_enabled = true
      subject.nfs_gss_enabled = true
      allow(subject).to receive(:FindPortmapper).and_return "portmap"

      # Stub some risky calls
      allow(subject).to receive(:firewalld).and_return(firewalld)
      allow(Yast::Progress).to receive(:set)
      allow(Yast::Service).to receive(:Enable)
      allow(Yast::SCR).to receive(:Execute)
        .with(path(".target.mkdir"), anything)
      allow(Yast::SCR).to receive(:Write)
        .with(path_matching(/^\.sysconfig\.nfs/), any_args)
      allow(Yast::SCR).to receive(:Write)
        .with(path_matching(/^\.etc\.idmapd_conf/), any_args)
      allow(firewalld).to receive(:installed?).and_return(true)
      allow(firewalld).to receive(:read)
      allow(firewalld).to receive(:write_only)
      # Creation of the backup
      allow(Yast::SCR).to receive(:Execute)
        .with(path(".target.bash"), %r{^/bin/cp }, any_args)

      # Load the lists
      subject.nfs_entries = nfs_entries
      allow(Yast::SCR).to receive(:Read).with(path(".etc.fstab"))
        .and_return fstab_entries
    end

    xit "ensures zero for 'passno' and 'freq' fields, only in nfs entries" do
      expected_passnos = {
        "/"            => 1,
        "/foof"        => nil,
        "/foo"         => 0,
        "/foo/bar"     => 0,
        "/foo/bar/baz" => 0
      }
      expected_freqs = {
        "/"            => nil,
        "/foof"        => 1,
        "/foo"         => 0,
        "/foo/bar"     => 2,
        "/foo/bar/baz" => 0
      }

      expect(Yast::SCR).to receive(:Write).with(path(".etc.fstab"), anything) do |_path, fstab|
        passnos = {}
        freqs = {}
        fstab.each do |e|
          passnos[e["file"]] = e["passno"]
          freqs[e["file"]] = e["freq"]
        end
        expect(passnos).to eq expected_passnos
        expect(freqs).to eq expected_freqs
      end

      subject.WriteOnly
    end
  end

  describe ".Write" do
    let(:fstab_entries) { YAML.load_file(File.join(DATA_PATH, "fstab_entries.yaml")) }
    let(:nfs_entries) { fstab_entries.select { |e| e["vfstype"] == "nfs" } }
    let(:written) { false }
    let(:portmapper) { "rpcbind" }

    before do
      subject.instance_variable_set("@portmapper", portmapper)
      subject.nfs_entries = nfs_entries
      allow(subject).to receive(:WriteOnly).and_return(written)
      allow(Yast::Wizard)
      allow(Yast::Progress).to receive(:set)
      allow(Yast::Service).to receive(:Start)
      allow(Yast::Service).to receive(:Stop)
      allow(Yast::Service).to receive(:active?)
    end

    it "writes the nfs configurations" do
      expect(subject).to receive(:WriteOnly)
      subject.Write()
    end

    context "when the configuration is written correctly" do
      let(:written) { true }

      it "stops the nfs service" do
        expect(Yast::Service).to receive(:Stop).with("nfs")
        subject.Write()
      end

      it "tries to start the portmapper service if it is not running" do
        expect(Yast::Service).to receive(:active?).with(portmapper).and_return(false)
        expect(Yast::Service).to receive(:Start).with(portmapper)
        subject.Write()
      end

      context "and the portmapper service was not activated" do
        before do
          allow(Yast::Service).to receive(:active?).with("rpcbind").twice.and_return(false)
          allow(Yast::Message).to receive(:CannotStartService).and_return("cannot_start")
        end

        it "reports an error" do
          expect(Yast::Report).to receive(:Error).with("cannot_start")

          subject.Write
        end

        it "returns false" do
          expect(subject.Write).to eql(false)
        end
      end

    end

    context "when the configuration is not written correctly" do
      before do
        allow(subject).to receive(:WriteOnly).and_return(false)
      end

      it "returns false" do
        expect(subject.Write).to eql(false)
      end
    end
  end

  describe ".legacy_entry?" do
    let(:all_entries) { YAML.load_file(File.join(DATA_PATH, "nfs_entries.yaml")) }
    let(:entries) { all_entries.map { |e| [e["file"], e] }.to_h }

    it "returns true for entries using nfs4 as vfstype" do
      expect(subject.legacy_entry?(entries["/two"])).to eq true
      expect(subject.legacy_entry?(entries["/four"])).to eq true
    end

    it "returns true for entries using minorversion in the mount options" do
      expect(subject.legacy_entry?(entries["/four"])).to eq true
      expect(subject.legacy_entry?(entries["/five"])).to eq true
    end

    it "returns false for entries without nfs4 or minorversion" do
      expect(subject.legacy_entry?(entries["/one"])).to eq false
      expect(subject.legacy_entry?(entries["/three"])).to eq false
    end
  end
end
