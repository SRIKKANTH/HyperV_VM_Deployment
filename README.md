Prerequisites:
1. Make sure Hyper-V is installed and configured with atleast 1 virtual switch. 
2. A Linux VHD with following:
	a. Root user password.
	b. Enable root to connect through ssh.
	c. Install "linux-cloud-tools-`uname -r`" package. (Without this HyperV cannot get IP address of the VM)
3. Keep following binaries in ".\bin" directory.
	a. dos2unix.exe
	b. plink.exe
	c. pscp.exe
	d. putty.exe
	e. puttygen.exe
4. Configure the  .xml file according to your requirements.

Execution:
Open powershell in Admin mode.
cd to "HyperVVMDeploy" folder.
Run ".\CreateVMs.ps1 <Your_Config_XML>"
