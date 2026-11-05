package request_parser

#assert(size_of(Kind) == 1 && align_of(Kind) == 1)
#assert(size_of(Fault) == 1 && align_of(Fault) == 1)

when size_of(int) == 8 {
	#assert(size_of(Result) == 40 && align_of(Result) == 8)
	#assert(size_of(Header_Result) == 32 && align_of(Header_Result) == 8)
	#assert(size_of(Limits) == 40 && align_of(Limits) == 8)
	#assert(size_of(Scratch) == 16 && align_of(Scratch) == 8)
	#assert(size_of(Inline_Owner) == 16 && align_of(Inline_Owner) == 8)
	#assert(size_of(Inline_Scan) == 24 && align_of(Inline_Scan) == 8)
}
