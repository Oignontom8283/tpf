.PHONY: build check test

build:
	./tpf build

check:
	./tpf check

test:
	python3 -m unittest discover -s tests
