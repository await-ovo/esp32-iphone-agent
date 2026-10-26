# Host unit tests for the firmware's pure-C parts. Usage: make -C hardware/tests
SRC = ../hid_bridge/src
CFLAGS = -std=c11 -Wall -Wextra -g -fsanitize=address,undefined
CXXFLAGS = -std=c++17 -Wall -Wextra -g -fsanitize=address,undefined -Istubs

all: test test_hid

test: test_main.c $(SRC)/hid/report.c
	$(CC) $(CFLAGS) -o $@ $^
	./test

report.o: $(SRC)/hid/report.c $(SRC)/hid/report.h
	$(CC) $(CFLAGS) -c -o $@ $<

test_hid: test_hid.cpp ../hid_bridge/hid_control.cpp report.o
	$(CXX) $(CXXFLAGS) -o $@ $^
	./test_hid

clean:
	rm -f test test_hid report.o

.PHONY: all clean
