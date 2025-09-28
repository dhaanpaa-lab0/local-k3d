all: clean
setup:
	@brew bundle
	mkdir -pv ./tmp
	mkdir -pv ./local
	mkdir -pv ./work
	mkdir -pv ./shared
	touch ./shared/.gitkeep
clean:
	@rm -rfv tmp/*
	@mkdir -pv /tmp
