.PHONY: build check test

build:
	./tpf.py build

check:
	./tpf.py check

test:
	python3 -m unittest discover -s tests
