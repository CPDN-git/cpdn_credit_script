# cpdn_credit_script
CPDN credit awarding script

This executable is built using the command:

g++ -I "../.."/lib -I "../.."/db -I "../.."/sched -I "../.." -I/usr/include/mysql cpdn_trickle_handler.cpp cpdn_credit.cpp cpdn_db.cpp -L/usr/lib64 -lmysqlclient -lpthread -lz -lm -lrt -lssl -lcrypto -ldl -L /usr/lib64/mysql -L ../../lib -L ../../sched -lsched -lboinc -o cpdn_credit

The executable then resides in the BOINC project bin folder.

In order for it to be executed on a regular basis by the BOINC project, the following needs to be added to the BOINC project config.xml file:

    <daemon>
      <cmd>cpdn_credit --variety year -dir /storage/www/cpdnboinc_alpha/trickle/ </cmd>
    </daemon>
