#!/bin/bash

# default user creds
username=aquatapuser
password=aquatapuser

# k3s
k3s_version=v1.24.4+k3s1
cri_dockerd_url=https://github.com/Mirantis/cri-dockerd/releases/download/v0.2.5/cri-dockerd_0.2.5.3-0.ubuntu-focal_amd64.deb


# cloudcmd
cloudcmd_namespace="cloudcmd"
local_cloudcmd_path="/vagrant_data/cloudcmd.yaml"

# jenkins
jenkins_helm_chart_version=4.1.18
local_jenkins_values_path="/vagrant_data/jenkins_${jenkins_helm_chart_version}_values.yaml"

# installation type
remote_resources=true
bootstrap_branch=master

# gitlab
use_gitlab=false
local_gitlab_values_path="/vagrant_data/gitlab.yaml"

# tools
k9s_version=v0.27.4
kubectx_version=v0.9.4

# Software Requirements
show_help(){
echo "Userscript for tap instance bootstrap.

Options available:
    -h              this help
    -u              [default: aquatapuser] username for ssh and jenkins 
    -p              [default: aquatapuser] user password
    -l              use local development helm and manifests
                    to be used together with the provided Vagrantfile
    -r              [default: true] user remote helm and manifests from the repo
                    options -l and -r can't be specified at the same time
    -j              specify a custom jenkins helm chart version; defaults to $jenkins_helm_chart_version
    -b              specify bootstrap branch from where to pull the installation resources (jenkins value file, cloudcmd manifests, etc...)
    -g              deploy gitlab instead of jenkins

Examples:

## Standard boostrap with values from github repo with custom creds and Jenkins version##
./user-script.sh -u aquatapuser -p aquatapuser -j 4.1.18

## Local vagrant deployment with default creds ##
./user-script.sh -l"
}

# Parsing arguments for username and password
while getopts h?u:p:j:b:glr flag
do
    case "${flag}" in
        h|\?)
            show_help
            exit 0
            ;;
        u) 
            username=$OPTARG
            ;;
        p) 
            password=$OPTARG
            ;;
        l) 
            local_resources=true
            remote_resources=false
            ;;
        j)
            jenkins_helm_chart_version=$OPTARG
            ;;
        b)
            bootstrap_branch=$OPTARG
            ;;
        g)
            use_gitlab=$OPTARG
    esac
done

user_home="/home/$username"

# deployments
deployment_resources_path="$user_home/deployments"


# Setup SSH password authentication
setup_ssh(){
    # Allow SSH password authentication
    sed -i 's/#\?PasswordAuthentication \(no\|yes\)/PasswordAuthentication yes/g' /etc/ssh/sshd_config
    sed -i 's/#\?ChallengeResponseAuthentication \(no\|yes\)/ChallengeResponseAuthentication yes/g' /etc/ssh/sshd_config
    systemctl restart sshd
}

create_users(){
    # Create user
    useradd -m -s /bin/bash -p $(perl -e "print crypt('$password', "salt")") -G sudo $username
}

setup_docker(){
    apt update && apt install -y docker.io

    # Install cri-dockerd wrapper for docker shim (required by k3s v1.24+)
    wget -O "/tmp/cri-dockerd.deb" $cri_dockerd_url
    apt install /tmp/cri-dockerd.deb -y

    # Add user to docker group
    usermod -a -G docker $username

}

setup_cri-dockerd(){
  # Install cri-dockerd
  VER=$(curl -s https://api.github.com/repos/Mirantis/cri-dockerd/releases/latest|grep tag_name | cut -d '"' -f 4|sed 's/v//g')
  wget https://github.com/Mirantis/cri-dockerd/releases/download/v${VER}/cri-dockerd-${VER}.amd64.tgz
  tar xvf cri-dockerd-${VER}.amd64.tgz
  mv cri-dockerd/cri-dockerd /usr/local/bin/

  # Setup systemd units
  wget https://raw.githubusercontent.com/Mirantis/cri-dockerd/master/packaging/systemd/cri-docker.service
  wget https://raw.githubusercontent.com/Mirantis/cri-dockerd/master/packaging/systemd/cri-docker.socket
  mv cri-docker.socket cri-docker.service /etc/systemd/system/
  sed -i -e 's,/usr/bin/cri-dockerd,/usr/local/bin/cri-dockerd,' /etc/systemd/system/cri-docker.service

  # Start and enable all services
  systemctl daemon-reload
  systemctl enable cri-docker.service
  systemctl enable --now cri-docker.socket

}

setup_k3s(){

    # setup dockershim requirement
    # requirement deprecated with v1.24.4+k3s1
    # setup_cri-dockerd

    # k3sup
    curl -sLS https://get.k3sup.dev | sh
    k3sup install --local --local-path=/root/kubeconfig --k3s-version=$k3s_version --k3s-extra-args "--disable-cloud-controller --disable traefik --disable servicelb --docker -o /home/$username/.kube/config"
    export KUBECONFIG=/root/kubeconfig

    # Give user r/w permission to kubeconfig
    chown $username: -R /home/$username/.kube
}

install_k8s_utilities(){
    # kubectx, kubens, k9s
    wget https://github.com/ahmetb/kubectx/releases/download/$kubectx_version/kubens -O /usr/local/bin/kubens
    wget https://github.com/ahmetb/kubectx/releases/download/$kubectx_version/kubectx -O /usr/local/bin/kubectx
    wget https://github.com/derailed/k9s/releases/download/$k9s_version/k9s_Linux_amd64.tar.gz -O /tmp/k9s_Linux_amd64.tar.gz
    tar xzvf /tmp/k9s_Linux_amd64.tar.gz -C /usr/local/bin/ k9s
    chmod +x /usr/local/bin/k*

    # helm
    snap install helm --classic
}

setup_userenv(){

    # kubectl autocompletion
    kubectl completion bash | sudo tee /etc/bash_completion.d/kubectl > /dev/null

    # env vars, bashrc and aliases
    cat <<END >>/home/$username/.bashrc
export KUBECONFIG=/home/$username/.kube/config

alias k=kubectl
alias kns=kubens
alias ktx=kubectx
alias h=helm

complete -F __start_kubectl k
END
}

# Jenkins
deploy_jenkins(){
    export KUBECONFIG=/root/kubeconfig

    helm repo add jenkins https://charts.jenkins.io

    # Wait until k3s is ready
    until kubectl get nodes; do sleep 1; done

    # Install Jenkins
    if [ $remote_resources == true ]; then
        helm upgrade --install jenkins jenkins/jenkins --version $jenkins_helm_chart_version -n jenkins --create-namespace -f https://raw.githubusercontent.com/aqua-ps/aqua-training-userscript/${bootstrap_branch}/jenkins_${jenkins_helm_chart_version}_values.yaml --set controller.adminUser=$username,controller.adminPassword=$password
    else
        helm upgrade --install jenkins jenkins/jenkins --version $jenkins_helm_chart_version -n jenkins --create-namespace -f $local_jenkins_values_path --set controller.adminUser=$username,controller.adminPassword=$password
    fi
}

deploy_cloudcmd(){
    export KUBECONFIG=/root/kubeconfig

    if [ $remote_resources == true ]; then
        wget https://raw.githubusercontent.com/aqua-ps/aqua-training-userscript/${bootstrap_branch}/cloudcmd.yaml -O /tmp/cloudcmd.yaml
        
        sed -i "s@CCMDNAMESPACE@$cloudcmd_namespace@g" /tmp/cloudcmd.yaml
        sed -i "s@DEPLOYMENTRESOURCES@$deployment_resources_path@g" /tmp/cloudcmd.yaml
        sed -i "s@CMDUSER@$username@g" /tmp/cloudcmd.yaml
        sed -i "s@CMDPASSWD@$password@g" /tmp/cloudcmd.yaml
        sed -i "s@CMDROOT@$user_home@g" /tmp/cloudcmd.yaml

        kubectl apply -f /tmp/cloudcmd.yaml
    else
        cp $local_cloudcmd_path /tmp/cloudcmd.yaml

        sed -i "s@CCMDNAMESPACE@$cloudcmd_namespace@g" /tmp/cloudcmd.yaml
        sed -i "s@DEPLOYMENTRESOURCES@$deployment_resources_path@g" /tmp/cloudcmd.yaml
        sed -i "s@CMDUSER@$username@g" /tmp/cloudcmd.yaml
        sed -i "s@CMDPASSWD@$password@g" /tmp/cloudcmd.yaml
        sed -i "s@CMDROOT@$user_home@g" /tmp/cloudcmd.yaml
        
        kubectl apply -f /tmp/cloudcmd.yaml
    fi

    rm /tmp/cloudcmd.yaml
}

download_deployment_resources(){
    cd $user_home
    rm -Rf deployments
    git clone https://github.com/aquasecurity/deployments.git
    chown "$username":"$username" -R $deployment_resources_path
}

deploy_gitlab() {
    export KUBECONFIG=/root/kubeconfig
    gitlab_url="http://gitlab-service.gitlab.svc.cluster.local"

    # Pre-download Gitlab image because it's a bit chunky and occasionally times out when k8s tries to pull it
    docker pull gitlab/gitlab-ce:latest

    echo "Installing Gitlab..."
    
    # Wait until k3s is ready
    until kubectl get nodes; do sleep 1; done
    
    echo "Remote deploy: $remote_resources"
    if [ $remote_resources == true ]; then
        wget https://raw.githubusercontent.com/aqua-ps/aqua-training-userscript/${bootstrap_branch}/gitlab.yaml -O /tmp/gitlab.yaml
        TOKEN=$(curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600") && public_host=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" -v http://169.254.169.254/latest/meta-data/public-hostname)
        # If ec2 instance, replace gitlab url with externally accessible name
        gitlab_url="http://$public_host:32080"
    else
        cp $local_gitlab_values_path /tmp/gitlab.yaml
    fi

    sed -i "s@EXTERNALURL@$gitlab_url@g" /tmp/gitlab.yaml
    sed -i "s@|PASSWORD|@$password@g" /tmp/gitlab.yaml
    
    echo "Applying /tmp/gitlab.yaml"
    kubectl apply -f /tmp/gitlab.yaml
    echo "Done."

    # setup demo repo and user
    git clone https://github.com/hdiv/insecure-bank.git

    kubectl rollout status deploy/gitlab -n gitlab -w
    echo "Modifying gitlab default user"
    kubectl exec deploy/gitlab -n gitlab -- gitlab-rails runner "user = User.find_by_username('root'); user.username='$username'; user.save! ; group = Group.create(name: 'default', path: 'default'); group.add_owner(user); group.save! "

    echo "Prepping demo repo"
    cd insecure-bank && git remote set-url origin http://$username:$password@127.0.0.1:32080/$username/insecure-bank.git
    git push origin master

}


setup_ssh
create_users
setup_docker
setup_k3s
install_k8s_utilities
setup_userenv

if $use_gitlab;
then
    deploy_gitlab
else
    deploy_jenkins
fi

deploy_cloudcmd
download_deployment_resources
