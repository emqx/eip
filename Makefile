PICS=$(patsubst %.uml,%.png,$(wildcard */*-assets/*.uml))

.PHONY: all
all: $(PICS)

%.png: %.uml
	plantuml $<
