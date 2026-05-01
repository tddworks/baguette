Baguette:
	./build.sh

clean:
	swift package clean 2>/dev/null || true
	rm -f Baguette

.PHONY: Baguette clean
