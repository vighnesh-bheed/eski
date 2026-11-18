package main

import "core:fmt"
import "core:sys/linux"
import "changelog"

CHANGE_LOG_APPENDONLY :: "change-log-dir requires appendonly yes"

CHANGE_LOG_PROTECTION :: "change-log-dir is incompatible with labels, owners, and encrypted persistence"

CHANGE_LOG_DIRECTORY :: "dir cannot change while change-log-dir is configured"

ERR_CHANGE_LOG_RELOAD :: "ERR DEBUG reload is incompatible with change-log-dir"

change_log_dir: string

change_log_limits: changelog.Limits

change_log_active: bool

@(private = "file")
change_log_state: changelog.Log

@(private = "file")
change_log_directory: changelog.Directory

@(private = "file")
change_log_db := i32(-1)

change_log_config_startup :: proc() {
	if change_log_dir == "" {
		return
	}
	if labels_on || owners_on || encryption_key_file != "" || encryption_key_file_previous != "" || encryption_adopt_plain {
		config_fatal(0, "", CHANGE_LOG_PROTECTION)
	}
	if !aof.wanted {
		config_fatal(0, "", CHANGE_LOG_APPENDONLY)
	}
	if change_log_limits.retain_bytes < change_log_limits.segment_bytes {
		config_fatal(0, "", "change-log-retain-bytes must be at least change-log-segment-bytes")
	}
}

@(private = "file")
change_log_open :: proc() -> (status: changelog.Status) {
	if status = changelog.directory_open(&change_log_directory, change_log_dir); status != .Ok {
		return
	}
	defer if status != .Ok {
		changelog.directory_close(&change_log_directory)
	}
	if status = changelog.directory_lock(&change_log_directory, true); status != .Ok {
		return
	}
	defer changelog.directory_unlock(&change_log_directory)
	if status = changelog.directory_claim(&change_log_directory); status != .Ok {
		return
	}
	disk := changelog.directory_disk(&change_log_directory)
	if status = changelog.recover(&change_log_state, disk, change_log_limits); status == .Ok {
		changelog.close(&change_log_state)
	} else if status != .Missing {
		return
	}
	epoch: changelog.Epoch
	if epoch, status = changelog.random_epoch(); status != .Ok {
		return
	}
	return changelog.begin(&change_log_state, disk, epoch, change_log_limits)
}

change_log_startup :: proc() {
	if change_log_dir == "" {
		return
	}
	if status := change_log_open(); status != .Ok {
		plog(LOG_WARNING, "Can't open the change log: ", fmt.tprintf("%v", status))
		linux.exit_group(1)
	}
	change_log_active = true
}

change_log_detach :: proc() {
	changelog.directory_close(&change_log_directory)
	change_log_active = false
}

change_log_stop :: proc(reason: string) {
	plog(LOG_WARNING, "Change log stopped; its current epoch will no longer accept records: ", reason)
	changelog.close(&change_log_state)
	change_log_detach()
}

change_log_aof_written :: proc() {
	if labels_on || owners_on || seal_on || aof.state != .Enabled {
		change_log_stop("incompatible persistence mode")
		return
	}
	status := changelog.directory_lock(&change_log_directory, true)
	if status == .Ok {
		status = changelog.append_record(&change_log_state, change_log_db, aof.buf[:])
		if status == .Ok {
			change_log_db = i32(aof.selected_db)
			changelog.directory_unlock(&change_log_directory)
			return
		}
	}
	change_log_stop(fmt.tprintf("%v", status))
}

change_log_aof_switched :: proc() {
	change_log_db = -1
}
