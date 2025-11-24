/*
 * Copyright (C) 2025  Isaac Joseph <calamityjoe87@gmail.com>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */


/* 
 * Generic WorkerPool: reusable background job queue with fixed worker threads.
 * Designed for light-weight background jobs (network I/O, decoding, etc.).
 */

public delegate void WorkerJob();

// Wrapper object to store a WorkerJob in Gee collections (generics require object types).
public class WorkerJobObj : GLib.Object {
    public WorkerJob job;
    public WorkerJobObj(WorkerJob j) {
        job = j;
    }
}

public class WorkerPool : GLib.Object {
    private static WorkerPool? _default = null;

    private Gee.ArrayList<WorkerJobObj> queue;
    private GLib.Mutex mutex;
    private GLib.Cond cond;
    private bool stopping;

    // Create or return a shared default pool (lazy init).
    public static WorkerPool get_default() {
        if (_default == null) _default = new WorkerPool(4);
        return _default;
    }

    // Construct a pool with `n_workers` background threads.
    public WorkerPool(int n_workers) {
    queue = new Gee.ArrayList<WorkerJobObj>();
        mutex = new GLib.Mutex();
        cond = new GLib.Cond();
        stopping = false;

        for (int i = 0; i < n_workers; i++) {
            // Spawn a detached worker thread that runs worker_loop.
            new Thread<void*>("pb-worker", () => { worker_loop(); return null; });
        }
    }

    private void worker_loop() {
        while (true) {
            WorkerJob? job = null;
            mutex.lock();
            while (queue.size == 0 && !stopping) {
                cond.wait(mutex);
            }
            if (stopping && queue.size == 0) {
                mutex.unlock();
                break;
            }
            try {
                var obj = queue.remove_at(0);
                if (obj != null) job = obj.job;
            } catch (GLib.Error e) {
                job = null;
            }
            mutex.unlock();

            if (job != null) {
                try {
                    job();
                } catch (GLib.Error e) {
                    // Swallow job errors to keep workers alive
                }
            }
        }
    }

    // Submit a job to the pool. The job may run soon after this returns.
    public void submit(WorkerJob job) {
        mutex.lock();
        queue.add(new WorkerJobObj(job));
        cond.signal();
        mutex.unlock();
    }

    // Mark the pool stopping; workers will exit when queue is drained.
    public void shutdown() {
        mutex.lock();
        stopping = true;
        cond.broadcast();
        mutex.unlock();
    }
}
