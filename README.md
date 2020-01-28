<b>Prerequisites: </b>
1. Make sure Hyper-V is installed and configured with atleast 1 virtual switch. Then update its name in below field of 'SampleConfig.xml'<br />
<nic>VMBUS,Default Switch</nic><br />
2. A Linux VHD with following:<br />
	a. Root user configured with password.<br />
	b. Enable root to connect through ssh.<br />
	c. Install "linux-cloud-tools-\`uname -r\`" package. (Without this HyperV cannot get IP address of the VM)<br />
		$ sudo apt install *\`uname -r\`*  # should install all the required packages<br />
		$ sudo apt install dhcpcd  # enables dhcp client on all attched NICs<br />
3. Keep following binaries in ".\bin" directory.<br />
	a. dos2unix.exe<br />
	b. plink.exe<br />
	c. pscp.exe<br />
	d. putty.exe<br />
	e. puttygen.exe<br />
4. Configure the  .xml file according to your requirements.<br />
<b>Execution: </b> <br />
Open powershell in Admin mode.<br />
cd to "HyperV_VM_Deployment" folder.<br />
Run ".\CreateVMs.ps1 <Your_Config_XML>"<br />
