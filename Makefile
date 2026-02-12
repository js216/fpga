TST := $(patsubst %.nw,obj_dir/Vtb_%,$(wildcard *.nw))
PDF := $(patsubst %.nw,%.pdf,$(wildcard *.nw))

all: $(PDF) $(TST)

obj_dir/Vtb_%: tb_%.sv %.v
	verilator -Wall --binary $^
	obj_dir/Vtb_$*

tb_%.sv: %.nw
	tangle $@ < $<

%.v: %.nw
	tangle $@ < $<

%.pdf: %.typ
	typst compile $<

%.typ: %.nw style.txt
	cp style.txt $@
	weave < $< >> $@

clean:
	rm -f *.typ *.v *.sv *.pdf
	rm -rf obj_dir
