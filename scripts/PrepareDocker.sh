. azuremodules.sh

function InstallDockerFromGetDockerDotCom ()
{
    sudo docker --version | grep "Docker version" | LogMsg
    if [ $? -eq 0 ]
	then
		sudo systemctl start docker
		echo "Docker already installed" | LogMsg
    else
		echo "Installing Docker" | LogMsg
		#TODO Should we install docker via someother means ?for example apt-get install docker-ce
		wget -qO- https://get.docker.com/ | sh

		if [ $? -ne 0 ] 
		then
			echo "docker install failed" | LogMsg
			return 1
		fi
		
		echo "Installing Docker:Done" | LogMsg
		# Commenting below out as currently custom extension script is run as root. 
		# The virtualmachine admin user has sudo permission currently so below may not be required anyways.
		# if required put in a seperate function and get admin user from FSM as here the $USER will always be root
		#sudo usermod -aG docker $USER
    fi
    DockerStatus=`get_service_status docker`
	if [ "x$DockerStatus" == "running" ]
	then
		echo "Docker Installed Succesfully"  | LogMsg
		return 1
	elif [ "x$DockerStatus" == "dead" ]
	then
		echo "Docker Installed succesfully but service not started" | LogMsg
		return 1
	elif [ "x$DockerStatus" == "ServiceNotFound" ]
	then
		echo "Error: Docker Installation Failed" | LogMsg
		return 2
	fi
}

function InstallDockerFromRepo ()
{
	curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add - | LogMsg  
	check_exit_status | LogMsg 
	sudo add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | LogMsg
	check_exit_status | LogMsg
	sudo apt-get update | LogMsg
	check_exit_status  | LogMsg
	sudo apt-cache policy docker-ce | LogMsg
	check_exit_status  | LogMsg
	sudo apt-get install -y docker-ce | LogMsg
	check_exit_status  | LogMsg
	sudo systemctl status docker | LogMsg
	check_exit_status  | LogMsg
	DockerStatus=`get_service_status docker`
	if [ "x$DockerStatus" == "running" ]
	then
		echo "Docker Installed Succesfully"  | LogMsg
		return 1
	elif [ "x$DockerStatus" == "dead" ]
	then
		echo "Docker Installed succesfully but service not started" | LogMsg
		return 1
	elif [ "x$DockerStatus" == "ServiceNotFound" ]
	then
		echo "Error: Docker Installation Failed" | LogMsg
		return 2
	fi
}

########################################################################
#
#	Execution starts from here
#
########################################################################
InstallDockerFromRepo
Status=$?
if [ $Status -eq 1 ]
then
	set_service_status docker restart
elif [ $Status -gt 1 ]
then
	echo "Warning: InstallDockerFromRepo failed to install 'docker'" | LogMsg
	InstallDockerFromGetDockerDotCom
	Status=$?
	if [ $Status -eq 1 ]
	then
		set_service_status docker restart
	elif [ $Status -gt 1 ]
	then
		echo "Failed to Install docker exitting now"
		echo "DOCKER_INSTALLATION_FAILED" | UpdateStatus
	fi
fi

echo "DOCKER_INSTALLATION_SUCCESS" | UpdateStatus
