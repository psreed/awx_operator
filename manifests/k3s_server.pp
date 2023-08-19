#######
# Module Name: awx_operator
# Written By: Paul Reed <paul.reed@perforce.com>
#
# Description: A simple installation for K3S server
#
# Adapted from: https://docs.k3s.io/quick-start
#
# Parameters:
# @param disable_swap - true: Disable swap, false: Leave swap as is, Defaults to true
#
# The following parameters are provided to specify locations of binaries that may be placed in different locations on different 
# operating systems. The defaults should work for most RHEL 8 and 9 systems and compatible variants, such as Alma, Rocky or Oracle Linux
#
# @param curl    - Location of binary
# @param grep    - Location of binary
# @param lsblk   - Location of binary
# @param sh      - Location of binary
# @param swapoff - Location of binary
#
class awx_operator::k3s_server (
  Boolean $disable_swap = true,
  String $curl          = $awx_operator::curl,
  String $grep          = $awx_operator::grep,
  String $lsblk         = $awx_operator::lsblk,
  String $sh            = $awx_operator::sh,
  String $swapoff       = $awx_operator::swapoff,
) {
  # K3S requires firewalld to be disabled 
  service { 'firewalld':
    ensure => stopped,
    enable => false,
  }

  # K3S suggests that swap be disabled
  if $disable_swap {
    exec { 'Disable Swap for K3S':
      command => "${swapoff} -a",
      onlyif  => "${lsblk} | ${grep} \"SWAP\"",
    }
  }

  exec { 'k3s-install':
    command => "${curl} -sfL https://get.k3s.io | ${sh} -s - --write-kubeconfig-mode 644",
    creates => '/etc/rancher/k3s/k3s.yaml',
  }
}
