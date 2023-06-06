package main

import "core:fmt"
import "core:strings"
import "core:mem"
import "core:math/rand"
import "core:strconv"
import "core:container/queue"
import "core:runtime"
import "formats:spall"

find_idx :: proc(events: []Event, val: f64) -> int {
	low := 0
	max := len(events)
	high := max - 1

	for low < high {
		mid := (low + high) / 2

		ev := events[mid]
		ev_start := ev.timestamp - total_min_time
		ev_end := ev_start + ev.duration

		if (val >= ev_start && val <= ev_end) {
			return mid
		} else if ev_start < val && ev_end < val { 
			low = mid + 1
		} else { 
			high = mid - 1
		}
	}

	return low
}

@export
start_loading_file :: proc "contextless" (size: u32, name: string) {
	context = wasmContext
	init_loading_state(size, name)
	get_chunk(0.0, f64(CHUNK_SIZE))

}

manual_load :: proc(config, name: string) {
	init_loading_state(u32(len(config)), name)
	load_config_chunk(transmute([]u8)config)
}

gen_event_color :: proc(events: []Event, thread_max: f64) -> (FVec3, f64) {
	total_weight : f64 = 0

	color := FVec3{}
	color_weights := [choice_count]f64{}
	for ev in events {
		idx := name_color_idx(in_getstr(ev.name))

		duration := f64(bound_duration(ev, thread_max))
		if duration <= 0 {
			//fmt.printf("weird duration: %d, %#v\n", duration, ev)
			duration = 0.1
		}
		color_weights[idx] += duration
		total_weight += duration
	}

	weights_sum : f64 = 0
	for weight, idx in color_weights {
		color += color_choices[idx] * f32(weight)
		weights_sum += weight
	}
	if weights_sum <= 0 {
		fmt.printf("Invalid weights sum! events: %d, %f, %f\n", len(events), weights_sum, total_weight)
		push_fatal(SpallError.Bug)
	}
	color /= f32(weights_sum)

	return color, total_weight
}

print_tree :: proc(tree: []ChunkNode, head: uint) {
	fmt.printf("mah tree!\n")
	// If we blow this, we're in space
	tree_stack := [128]uint{}
	stack_len := 0
	pad_buf := [?]u8{0..<64 = '\t',}

	tree_stack[0] = head; stack_len += 1
	for stack_len > 0 {
		stack_len -= 1

		tree_idx := tree_stack[stack_len]
		cur_node := tree[tree_idx]

		//padding := pad_buf[len(pad_buf) - stack_len:]
		fmt.printf("%d | %v\n", tree_idx, cur_node)

		if cur_node.child_count == 0 {
			continue
		}

		for i := (cur_node.child_count - 1); i >= 0; i -= 1 {
			tree_stack[stack_len] = cur_node.children[i]; stack_len += 1
		}
	}
	fmt.printf("ded!\n")
}

chunk_events :: proc() {
	for proc_v, p_idx in &processes {
		for tm, t_idx in &proc_v.threads {
			for depth, d_idx in &tm.depths {
				bucket_count := i_round_up(len(depth.events), BUCKET_SIZE) / BUCKET_SIZE

				// precompute element count for tree
				max_nodes := bucket_count
				{
					row_count := bucket_count
					parent_row_count := (row_count + (CHUNK_NARY_WIDTH - 1)) / CHUNK_NARY_WIDTH
					for row_count > 1 {
						tmp := (row_count + (CHUNK_NARY_WIDTH - 1)) / CHUNK_NARY_WIDTH
						max_nodes += tmp
						row_count = parent_row_count
						parent_row_count = tmp
					}
				}

				tm.depths[d_idx].tree = make([dynamic]ChunkNode, 0, max_nodes, big_global_allocator)
				tree := &tm.depths[d_idx].tree

				for i := 0; i < bucket_count; i += 1 {
					start_idx := i * BUCKET_SIZE
					end_idx := start_idx + min(len(depth.events) - start_idx, BUCKET_SIZE)
					scan_arr := depth.events[start_idx:end_idx]

					start_ev := scan_arr[0]
					end_ev := scan_arr[len(scan_arr)-1]

					node := ChunkNode{}
					node.start_time = start_ev.timestamp - total_min_time
					node.end_time   = end_ev.timestamp + bound_duration(end_ev, tm.max_time) - total_min_time
					node.start_idx  = uint(start_idx)
					node.end_idx    = uint(end_idx)
					node.arr_len = i8(len(scan_arr))

					avg_color, weight := gen_event_color(scan_arr, tm.max_time)
					node.avg_color = avg_color
					node.weight = weight

					append(tree, node)
				}

				tree_start_idx := 0
				tree_end_idx := len(tree)

				row_count := len(tree)
				parent_row_count := (row_count + (CHUNK_NARY_WIDTH - 1)) / CHUNK_NARY_WIDTH
				for row_count > 1 {
					for i := 0; i < parent_row_count; i += 1 {
						start_idx := tree_start_idx + (i * CHUNK_NARY_WIDTH)
						end_idx := start_idx + min(tree_end_idx - start_idx, CHUNK_NARY_WIDTH)

						children := tree[start_idx:end_idx]

						start_node := children[0]
						end_node := children[len(children)-1]

						node := ChunkNode{}
						node.start_time = start_node.start_time
						node.end_time   = end_node.end_time
						node.start_idx  = start_node.start_idx
						node.end_idx    = end_node.end_idx

						avg_color := FVec3{}
						for j := 0; j < len(children); j += 1 {
							node.children[j] = uint(start_idx + j)
							avg_color += children[j].avg_color * f32(children[j].weight)
							node.weight += children[j].weight
						}
						node.child_count = i8(len(children))
						node.avg_color = avg_color / f32(node.weight)

						append(tree, node)
					}

					tree_start_idx = tree_end_idx
					tree_end_idx = len(tree)
					row_count = tree_end_idx - tree_start_idx
					parent_row_count = (row_count + (CHUNK_NARY_WIDTH - 1)) / CHUNK_NARY_WIDTH
				}

				depth.head = len(tree) - 1
			}
		}
	}
}

generate_selftimes :: proc() {
	for proc_v, p_idx in &processes {
		for tm, t_idx in &proc_v.threads {

			// skip the bottom rank, it's already set up correctly
			if len(tm.depths) == 1 {
				continue
			}

			for depth, d_idx in &tm.depths {
				// skip the last depth
				if d_idx == (len(tm.depths) - 1) {
					continue
				}

				for ev, e_idx in &depth.events {
					depth := tm.depths[d_idx+1]
					tree := depth.tree

					tree_stack := [128]uint{}
					stack_len := 0

					start_time := ev.timestamp - total_min_time
					end_time := ev.timestamp + bound_duration(ev, tm.max_time) - total_min_time

					child_time := 0.0
					tree_stack[0] = depth.head; stack_len += 1
					for stack_len > 0 {
						stack_len -= 1

						tree_idx := tree_stack[stack_len]
						cur_node := tree[tree_idx]

						if end_time < cur_node.start_time || start_time > cur_node.end_time {
							continue
						}

						if cur_node.start_time >= start_time && cur_node.end_time <= end_time {
							child_time += cur_node.weight
							continue
						}

						if cur_node.child_count == 0 {
							scan_arr := depth.events[cur_node.start_idx:cur_node.start_idx+uint(cur_node.arr_len)]
							weight := 0.0
							scan_loop: for scan_ev in scan_arr {
								scan_ev_start_time := scan_ev.timestamp - total_min_time
								if scan_ev_start_time < start_time {
									continue
								}

								scan_ev_end_time := scan_ev.timestamp + bound_duration(scan_ev, tm.max_time) - total_min_time
								if scan_ev_end_time > end_time {
									break scan_loop
								}

								weight += bound_duration(scan_ev, tm.max_time)
							}
							child_time += weight
							continue
						}

						for i := cur_node.child_count - 1; i >= 0; i -= 1 {
							tree_stack[stack_len] = cur_node.children[i]; stack_len += 1
						}
					}

					ev.self_time = bound_duration(ev, tm.max_time) - child_time
				}
			}
		}
	}
}

instant_count := 0
first_chunk: bool
init_loading_state :: proc(size: u32, name: string) {
	ingest_start_time = u64(get_time())

	b := strings.builder_from_slice(file_name_store[:])
	strings.write_string(&b, name)
	file_name = strings.to_string(b)

	// reset selection state
	clicked_on_rect = false
	did_multiselect = false
	stats_state = .NoStats
	total_tracked_time = 0.0
	selected_event = EventID{-1, -1, -1, -1}

	// wipe all allocators
	free_all(scratch_allocator)
	free_all(scratch2_allocator)
	free_all(small_global_allocator)
	free_all(big_global_allocator)
	free_all(temp_allocator)
	processes = make([dynamic]Process, small_global_allocator)
	process_map = vh_init(scratch_allocator)
	global_instants = make([dynamic]Instant, big_global_allocator)
	string_block = make([dynamic]u8, big_global_allocator)
	stats = sm_init(big_global_allocator)
	selected_ranges = make([dynamic]Range, 0, big_global_allocator)
	total_max_time = 0
	total_min_time = 0x7fefffffffffffff

	last_read = 0
	first_chunk = true
	event_count = 0
	instant_count = 0

	bp = init_parser(size)
	
	loading_config = true
	post_loading = false

	fmt.printf("Loading a %.1f MB config\n", f64(size) / 1024 / 1024)
	start_bench("parse config")
}

is_json := false
finish_loading :: proc () {
	stop_bench("parse config")
	fmt.printf("Got %d events, %d instants\n", event_count, instant_count)

	free_all(temp_allocator)
	free_all(scratch_allocator)
	free_all(scratch2_allocator)

	start_bench("process and sort events")
	if is_json {
		json_process_events()
	} else {
		bin_process_events()
	}
	stop_bench("process and sort events")

	free_all(temp_allocator)
	free_all(scratch_allocator)

	generate_color_choices()

	start_bench("generate spatial partitions")
	chunk_events()
	stop_bench("generate spatial partitions")

	start_bench("generate self-time")
	if is_json {
		generate_selftimes()
	}
	stop_bench("generate self-time")

	t = 0
	frame_count = 0

	free_all(temp_allocator)
	free_all(scratch_allocator)
	queue.init(&fps_history, 0, small_global_allocator)

	loading_config = false
	post_loading = true

	ingest_end_time := u64(get_time())
	time_range := ingest_end_time - ingest_start_time
	fmt.printf("runtime: %fs (%dms)\n", f32(time_range) / 1000, time_range)
	return
}

jp: JSONParser
stamp_scale: f64
@export
load_config_chunk :: proc "contextless" (chunk: []u8) {
	context = wasmContext
	defer free_all(context.temp_allocator)

	if first_chunk {
		header_sz := size_of(spall.Header)
		if len(chunk) < header_sz {
			fmt.printf("Uh, you passed me an empty file?\n")
			finish_loading()
			return
		}
		magic := (^u64)(raw_data(chunk))^

		is_json = false
		if magic == spall.MANUAL_MAGIC {
			hdr := cast(^spall.Header)raw_data(chunk)
			if hdr.version != 1 {
				fmt.printf("Your file version (%d) is not supported!\n", hdr.version)
				push_fatal(SpallError.InvalidFileVersion)
			}

			stamp_scale = hdr.timestamp_unit
			bp.pos += i64(header_sz)
		} else if magic == spall.NATIVE_MAGIC {
			fmt.printf("You're trying to use a native-version file on the web!\n")
			push_fatal(SpallError.NativeFileDetected)
		} else {
			is_json = true
			stamp_scale = 1
			jp = init_json_parser()
		}

		first_chunk = false
	}

	if is_json {
		load_json_chunk(&jp, chunk)
	} else {
		load_binary_chunk(chunk)
	}

	return
}

bound_duration :: proc(ev: $T, max_ts: f64) -> f64 {
	return ev.duration == -1 ? (max_ts - ev.timestamp) : ev.duration
}

append_event :: proc(array: ^[dynamic]Event, arg: Event) {
	if cap(array) < (len(array) + 1) {

		capacity := 2 * cap(array)
		a := (^runtime.Raw_Dynamic_Array)(array)

		old_size  := a.cap * size_of(Event)
		new_size  := capacity * size_of(Event)

		allocator := a.allocator

		new_data, err := allocator.procedure(
			allocator.data, .Resize, new_size, align_of(Event),
			a.data, old_size)

		a.data = raw_data(new_data)
		a.cap = capacity
	}

	if (cap(array) - len(array)) > 0 {
		a := (^runtime.Raw_Dynamic_Array)(array)
		data := ([^]Event)(a.data)
		data[a.len] = arg
		a.len += 1
	}
}

default_config_name :: "../demos/cuik_c_compiler.json"
default_config := string(#load(default_config_name))
