all: cpdn_credit

MYSQL_CFLAGS = -I/usr/include/mysql
MYSQL_LIBS = -L/usr/lib64 -lmysqlclient -lpthread -lz -lm -lrt -lssl -lcrypto -ldl

BOINC = "../.."
CC = g++ \
         -I $(BOINC)/lib -I $(BOINC)/db -I $(BOINC)/sched -I $(BOINC) \
         $(MYSQL_CFLAGS)

SRC =  cpdn_trickle_handler.cpp \
        cpdn_credit.cpp \
        cpdn_db.cpp

LIBS = -L /usr/lib64/mysql -L ../../lib -L ../../sched -lsched -lboinc

cpdn_credit: cpdn_credit.cpp
        $(CC) $(SRC) $(MYSQL_LIBS) $(LIBS) -o cpdn_credit
