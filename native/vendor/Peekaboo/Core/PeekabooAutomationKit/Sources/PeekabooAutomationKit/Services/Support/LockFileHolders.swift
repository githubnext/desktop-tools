import Darwin
import Foundation

/// Finds the processes that have a lock file open, so a lock timeout can name what is blocking it.
enum LockFileHolders {
    static let maximumListed = 8

    /// Processes of this user with the file open, as "name (pid N, executable)". Others' processes are unreadable.
    static func describe(path: String) -> [String] {
        var target = stat()
        guard stat(path, &target) == 0 else { return [] }
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.stride))
        guard filled > 0 else { return [] }
        var result: [String] = []
        for pid in pids.prefix(Int(filled))
            where pid > 0 && self.hasOpen(pid: pid, device: target.st_dev, inode: target.st_ino)
        {
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
            let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
            let executable = length > 0 ? String(cString: buffer) : "unknown executable"
            let name = (executable as NSString).lastPathComponent
            result.append("\(name) (pid \(pid)\(pid == getpid() ? ", this process" : ""), \(executable))")
            if result.count == self.maximumListed { break }
        }
        return result
    }

    private static func hasOpen(pid: pid_t, device: dev_t, inode: ino_t) -> Bool {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return false }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / stride + 16)
        let filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &descriptors, Int32(descriptors.count * stride))
        guard filled > 0 else { return false }
        let infoSize = Int32(MemoryLayout<vnode_fdinfowithpath>.stride)
        for descriptor in descriptors.prefix(Int(filled) / stride)
            where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_VNODE)
        {
            var info = vnode_fdinfowithpath()
            guard proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, infoSize) == infoSize
            else { continue }
            let stat = info.pvip.vip_vi.vi_stat
            if UInt64(stat.vst_ino) == UInt64(inode), Int64(stat.vst_dev) == Int64(device) { return true }
        }
        return false
    }
}
