import lldb
count = 0

def capture(frame, bp_loc, internal_dict):
    global count
    thread = frame.GetThread()
    if thread.GetIndexID() == 1:
        return False
    count += 1
    with open('/Users/bill/Desktop/SkyBridge Compass Pro release/design/weather/20260909-drawable-lifecycle/texture-access-stacks.txt', 'a') as output:
        output.write('TEXTURE ACCESS on thread index %s id %s\n' % (thread.GetIndexID(), thread.GetThreadID()))
        for item in thread:
            output.write('%s : %s\n' % (item.GetModule().GetFileSpec().GetFilename(), item.GetFunctionName()))
        output.write('\n')
    if count >= 8:
        bp_loc.GetBreakpoint().SetEnabled(False)
    return False

def capture_stale(frame, bp_loc, internal_dict):
    error = lldb.SBError()
    receiver = frame.FindRegister('x0').GetValueAsUnsigned()
    backing = frame.GetThread().GetProcess().ReadPointerFromMemory(receiver + 8, error)
    if not error.Success() or backing != 0:
        return False
    with open('/Users/bill/Desktop/SkyBridge Compass Pro release/design/weather/20260909-drawable-lifecycle/stale-drawable-stack.txt', 'a') as output:
        output.write('Drawable backing is nil: the exact warning branch in CAMetalDrawable.texture\n')
        for item in frame.GetThread():
            output.write('%s : %s\n' % (item.GetModule().GetFileSpec().GetFilename(), item.GetFunctionName()))
    bp_loc.GetBreakpoint().SetEnabled(False)
    return False
