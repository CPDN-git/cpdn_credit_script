# Instruction on building and deploying the CPDN credit awarding script

First to your project's server, download the BOINC code from:

https://github.com/BOINC/boinc

Within the downloaded folder make a folder called 'server', within that make another folder called 'cpdn_credit', then download this repository into this.

Then build the cpdn_credit executable on your project's server (the same machine as the credit script will be running) using the command:

g++ -I "../.."/lib -I "../.."/db -I "../.."/sched -I "../.." -I/usr/include/mysql cpdn_trickle_handler.cpp cpdn_credit.cpp cpdn_db.cpp -L/usr/lib64 -lmysqlclient -lpthread -lz -lm -lrt -lssl -lcrypto -ldl -L /usr/lib64/mysql -L ../../lib -L ../../sched -lsched -lboinc -o cpdn_credit

This executable then needs to be moved to your BOINC project's 'bin' folder.

In order for it to be executed on a regular basis by the BOINC project, the following needs to then be added to the BOINC project config.xml file (fill in the path to the project directory):

    <daemon>
      <cmd>cpdn_credit -dir /PROJECT_DIRECTORY/trickle/ </cmd>
    </daemon>
    
Now finally stop and start your BOINC project.
