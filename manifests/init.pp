#######
# Module Name: awx_operator
# Written By: Paul Reed <paul.reed@perforce.com>
#
# Description: Simple installation and management of AWX Operator including a K3S based Kubernetes server.
#
# Adapted from: https://github.com/ansible/awx-operator
#
# Tested on: 
# - RedHat Enterprise Linux 9.2
# - Note: will likely run on many other versions of RedHat Enterprise Linux and other RPM based Enterprise Linux variants.
#
# Parameter definitions:
# @param awx_admin_password       - AWX 'admin' user password
# @param awx_namespace            - K8S namespace for AWX Operator
# @param awx_nodeport             - Nodeport to use for the application (30080 is the default)
# @param awx_operator_version     - Version of AWX to deploy (must match a tag from the source code repo)
# @param awx_project_mount_path   - AWX Project mount path
# @param awx_source_local_folder  - Local folder in which to store source code
# @param awx_source_repo          - AWX Operator source repository (for air gap use)
# @param manage_k3s               - Install and manage a minimal Kubernetes implementation, currently 'true' is the only supported option
# @param set_namespace_as_default - Set the namespace to be used as default for 'kubectl'
#
# The following parameters are provided to specify locations of binaries that may be placed in different locations on different 
# operating systems. The defaults should work for most RHEL 8 and 9 systems and compatible variants, such as Alma, Rocky or Oracle Linux
#
# @param base64  - Location of binary
# @param cat     - Location of binary
# @param curl    - Location of binary
# @param git     - Location of binary
# @param grep    - Location of binary
# @param jq      - Location of binary
# @param kubectl - Location of binary
# @param lsblk   - Location of binary
# @param make    - Location of binary
# @param mkdir   - Location of binary
# @param sh      - Location of binary
# @param swapoff - Location of binary
#
class awx_operator (
  Sensitive[String] $awx_admin_password = 'Change Me!',
  String  $awx_namespace                = 'awx',
  Integer $awx_nodeport                 = 30080,
  String  $awx_operator_version         = '2.5.1',
  String  $awx_project_mount_path       = '/var/lib/projects',
  String  $awx_source_local_folder      = '/root',
  String  $awx_source_repo              = 'https://github.com/ansible/awx-operator.git',
  Boolean $manage_k3s                   = true,
  Boolean $set_namespace_as_default     = true,

  String $base64  = '/usr/bin/base64',
  String $cat     = '/usr/bin/cat',
  String $curl    = '/usr/bin/curl',
  String $git     = '/usr/bin/git',
  String $grep    = '/usr/bin/grep',
  String $jq      = '/usr/bin/jq',
  String $kubectl = '/usr/local/bin/kubectl',
  String $lsblk   = '/usr/bin/lsblk',
  String $make    = '/usr/bin/make',
  String $mkdir   = '/usr/bin/mkdir',
  String $sh      = '/usr/bin/sh',
  String $swapoff = '/usr/sbin/swapoff',
) {
  # Install/Manage K3S before main stage
  stage { 'k3s_install': }
  Stage['k3s_install'] -> Stage['main']
  if $manage_k3s {
    class { 'awx_operator::k3s_server': stage => 'k3s_install' }
  }

  # Ensure required packages exist
  ensure_packages(['git','make','jq','curl'])

  # Create namespace
  exec { 'AWX Namespace':
    command => "${kubectl} create ns \"${awx_namespace}\"",
    unless  => "${kubectl} get ns | ${grep} \"${awx_namespace}\"",
  }

  # Set namespace as default
  if $set_namespace_as_default {
    exec { 'AWX Namespace as Default':
      command => "${kubectl} config set-context --current --namespace=\"${awx_namespace}\"",
      unless  => "${kubectl} config get-contexts | ${grep} default | ${grep} \"${awx_namespace}\"",
      require => Exec['AWX Namespace'],
    }
  }

  # Ensure local folder for source code repo exists
  exec { 'Create AWX Local Source Folder':
    command => "${mkdir} -p ${awx_source_local_folder}",
    creates => $awx_source_local_folder,
  }

  # Clone source repo locally
  exec { 'Clone AWX Repo':
    cwd     => $awx_source_local_folder,
    command => "${git} clone ${awx_source_repo}",
    creates => "${awx_source_local_folder}/awx-operator/.git",
    require => [Package['git']],
  }

  # Deploy AWX Operator into K3S
  exec { 'Deploy AWX Operator':
    cwd     => "${awx_source_local_folder}/awx-operator",
    command => "${git} checkout tags/${awx_operator_version}; ${make} deploy",
    onlyif  => "${kubectl} get pods -n \"${awx_namespace}\" 2>&1 | ${grep} \"No resources found in\"",
    require => [Exec['Clone AWX Repo']],
  }

  # Configure AWX deployment persistent volume claim
  exec { 'Configure AWX Deployment - Persistent Volume Claim':
    path    => $awx_source_local_folder,
    cwd     => $awx_source_local_folder,
    command => "${cat} <<EOF | ${kubectl} create -f -\n${epp('awx_operator/awx-deployment-pvs.epp')}\nEOF\n",
    unless  => "${kubectl} get PersistentVolumeClaim | ${grep} awx-projects-claim | ${grep} Bound",
    require => Exec['Deploy AWX Operator'],
  }

  # Configure AWX deployment persistent volume & NodePort service
  exec { 'Configure AWX Deployment - Persistent Volume & NodePort Service':
    path    => $awx_source_local_folder,
    cwd     => $awx_source_local_folder,
    command => "${cat} <<EOF | ${kubectl} create -f -\n${epp('awx_operator/awx-deployment-config.epp')}\nEOF\n",
    unless  => "${kubectl} get svc | ${grep} ${awx_nodeport}",
    require => Exec['Configure AWX Deployment - Persistent Volume Claim'],
  }

  # Wait for deployment
  exec { 'Wait for AWX Deployment':
    command => "${kubectl} wait --for=condition=available --timeout=10m --all deployments",
    unless  => "${kubectl} get deployments | ${grep} awx-web | ${grep} \"1/1\"",
    require => Exec['Configure AWX Deployment - Persistent Volume & NodePort Service'],
  }

  # Set AWX Deployment Password
  # Adapted from: https://kubernetes.io/docs/tasks/configmap-secret/managing-secret-using-kubectl/
  exec { 'Set AWX Admin Password':
    path    => $awx_source_local_folder,
    command => "${cat} <<EOF | ${kubectl} apply -f -\n${epp('awx_operator/awx-set-admin-password.epp', {
        'admin_user_b64' => base64('encode','admin'),
        'admin_pass_b64' => base64('encode',$awx_admin_password)
    })}\nEOF\n",
    unless  => "${kubectl} get secret awx-admin-password -o jsonpath='{.data}' | ${jq} -r '.password' | ${base64} -d | ${grep} ${awx_admin_password}", #lint:ignore:140chars
    require => Exec['Wait for AWX Deployment'],
  }
}
