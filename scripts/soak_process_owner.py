"""Reap exact Popen children without relying on writable diagnostics.

No PID-file signaling, process groups, global handlers or unowned descendants.
Only the controller's directly returned handles may be stopped here.
"""
import subprocess


def reap_owned(child, request_stop=None, grace=90, terminate_grace=10):
    if child is None:
        return None
    result = dict(pid=child.pid, reaped=False, exit=None, stopRequested=False,
                  terminated=False, killed=False, errors=[])

    def fault(stage, error):
        result['errors'].append(dict(stage=stage, type=type(error).__name__))

    def wait_for(seconds):
        try:
            child.wait(timeout=seconds)
            return True
        except subprocess.TimeoutExpired:
            return False
        except BaseException as error:
            fault('wait', error)
            return False

    if child.poll() is None and request_stop is not None:
        try:
            request_stop()
            result['stopRequested'] = True
        except BaseException as error:
            # A full disk must never skip termination or actual wait/reaping.
            fault('request-stop', error)
        if result['stopRequested']:
            wait_for(grace)
    if child.poll() is None:
        try:
            child.terminate()
            result['terminated'] = True
        except ProcessLookupError:
            pass
        except BaseException as error:
            fault('terminate', error)
        wait_for(terminate_grace)
    if child.poll() is None:
        try:
            child.kill()
            result['killed'] = True
        except ProcessLookupError:
            pass
        except BaseException as error:
            fault('kill', error)
    # A timeout is never an acknowledgement that a process has stopped.
    # Interruptions during cleanup still join the exact child before returning.
    while True:
        try:
            result['exit'] = child.wait()
            result['reaped'] = True
            break
        except (KeyboardInterrupt, InterruptedError) as error:
            fault('final-wait', error)
            if child.poll() is None:
                try:
                    child.kill()
                    result['killed'] = True
                except ProcessLookupError:
                    pass
                except BaseException as nested:
                    fault('kill-after-interrupt', nested)
        except BaseException as error:
            fault('final-wait', error)
            break
    return result


def reap_all(worker, fixture, request_stop=None, grace=90, terminate_grace=10):
    """Always attempt both children, including if one cleanup itself fails."""
    outcomes = {}
    for name, child in [('worker', worker), ('fixture', fixture)]:
        try:
            outcomes[name] = reap_owned(child, request_stop if name == 'worker' else None,
                                        grace, terminate_grace)
        except BaseException as error:
            # An unexpected cleanup error must still attempt this exact handle,
            # then continue to the other child. Never use a PID-file fallback.
            value = dict(pid=child.pid if child else None, reaped=False, exit=None,
                         killed=False, errors=[dict(stage='cleanup', type=type(error).__name__)])
            if child is not None:
                try:
                    child.kill()
                    value['killed'] = True
                except ProcessLookupError:
                    pass
                except BaseException as nested:
                    value['errors'].append(dict(stage='fallback-kill', type=type(nested).__name__))
                while True:
                    try:
                        value['exit'] = child.wait()
                        value['reaped'] = True
                        break
                    except (KeyboardInterrupt, InterruptedError) as nested:
                        value['errors'].append(dict(stage='fallback-wait', type=type(nested).__name__))
                    except BaseException as nested:
                        value['errors'].append(dict(stage='fallback-wait', type=type(nested).__name__))
                        break
            outcomes[name] = value
    return outcomes
