"""Synthetic LLDB check. Not an authorized physical-device reader."""
import json
import os
import time

import lldb


def check(debugger, command, result, internal_dict):
    process = None
    stage = "target"
    try:
        debugger.SetAsync(False)
        target = debugger.CreateTarget(command.strip())
        assert target.IsValid()
        ready = target.BreakpointCreateByRegex("probeReady")
        finished = target.BreakpointCreateByRegex("probeFinished")
        assert ready.GetNumLocations() and finished.GetNumLocations()
        error = lldb.SBError()
        launch = lldb.SBLaunchInfo([])
        launch.SetLaunchFlags(lldb.eLaunchFlagDebug)
        stage = "launch"
        process = target.Launch(launch, error)
        if error.Fail():
            # The target contains synthetic fixtures only, never an installed app.
            print(json.dumps({"synthetic_launch_error": error.GetCString(),
                "error_code": error.GetError(), "error_type": error.GetType()}, sort_keys=True))
        elif process.GetState() != lldb.eStateStopped:
            print(json.dumps({"synthetic_launch_state": process.GetState()}, sort_keys=True))
        assert error.Success() and process.GetState() == lldb.eStateStopped
        pid = process.GetProcessID()
        options = lldb.SBExpressionOptions()
        options.SetLanguage(lldb.eLanguageTypeObjC_plus_plus)
        options.SetTimeoutInMicroSeconds(2_000_000)
        options.SetTryAllThreads(False)
        options.SetStopOthers(True)
        options.SetUnwindOnError(True)
        options.SetIgnoreBreakpoints(True)
        options.SetSuppressPersistentResult(True)
        options.SetPrefix("""extern "C" void *objc_getClass(const char *name);
@class NSString;
@interface HealthCompStagingScoringOperator
+ (bool)arm;
+ (NSString *)take;
+ (bool)cancel;
@end
""")

        def evaluate(expression):
            frame = process.GetSelectedThread().GetFrameAtIndex(0)
            value = frame.EvaluateExpression(expression, options)
            if value.GetError().Fail():
                print(json.dumps({"synthetic_expression_stage": stage,
                    "synthetic_expression_error": value.GetError().GetCString()}, sort_keys=True))
            assert value.IsValid() and value.GetError().Success()
            return value

        stage = "default_off"
        assert evaluate('(id)[(id)objc_getClass("HealthCompStagingScoringOperator") take]').GetValueAsUnsigned() == 0
        stage = "arm"
        assert evaluate('(int)[(id)objc_getClass("HealthCompStagingScoringOperator") arm]').GetValueAsSigned() == 1
        assert evaluate('(int)[(id)objc_getClass("HealthCompStagingScoringOperator") arm]').GetValueAsSigned() == 0
        ready.SetEnabled(False)
        stage = "synthetic_response"
        continued = process.Continue()
        until = time.monotonic() + 5
        while process.GetState() not in (lldb.eStateStopped, lldb.eStateExited, lldb.eStateCrashed) and time.monotonic() < until:
            time.sleep(0.01)
        if continued.Fail() or process.GetState() != lldb.eStateStopped:
            print(json.dumps({"synthetic_continue_success": continued.Success(),
                "synthetic_continue_state": process.GetState()}, sort_keys=True))
        assert continued.Success() and process.GetState() == lldb.eStateStopped
        stage = "private_take"
        value = evaluate('(id)[(id)objc_getClass("HealthCompStagingScoringOperator") take]')
        description = value.GetObjectDescription()
        assert description == "00000000-0000-4000-8000-000000000001"
        del description, value
        assert evaluate('(id)[(id)objc_getClass("HealthCompStagingScoringOperator") take]').GetValueAsUnsigned() == 0
        assert evaluate('(int)[(id)objc_getClass("HealthCompStagingScoringOperator") arm]').GetValueAsSigned() == 0
        stage = "persistent_variables"
        assert evaluate('(int)[(id)objc_getClass("HealthCompStagingScoringOperator") cancel]').GetValueAsSigned() == 1
        assert evaluate('(id)[(id)objc_getClass("HealthCompStagingScoringOperator") take]').GetValueAsUnsigned() == 0
        # Apple LLDB lacks SBTarget.FindExpressionVariableForLanguage. These
        # fixed lookups use its supported evaluator and suppress their results too.
        frame = process.GetSelectedThread().GetFrameAtIndex(0)
        slots = [frame.EvaluateExpression("$" + str(index), options)
            for index in range(16)]
        assert all(v.GetError().Fail() for v in slots)
        stage = "detach"
        finished.SetEnabled(False)
        assert process.Detach(False).Success()
        for _ in range(40):
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                break
            time.sleep(0.05)
        else:
            raise AssertionError()
        print(json.dumps({"status": "synthetic_debugger_access_passed",
            "default_off": True, "one_arm": True, "destructive_take": True,
            "explicit_cancel_confirmed": True,
            "printed_response_ids": 0, "checked_persistent_result_slots": 16,
            "synthetic_inferior_exited_after_detach": True,
            "real_app_owner_wiring_proven": False, "physical_attach_proven": False,
            "hosted_queries": 0, "phone_actions": 0}, sort_keys=True))
    except Exception:
        result.SetError("synthetic_debugger_check_failed:" + stage)
    finally:
        if process is not None and process.IsValid() and process.GetState() not in (
            lldb.eStateExited, lldb.eStateDetached, lldb.eStateInvalid):
            process.Kill()  # Only this fixture's newly launched inferior.


def __lldb_init_module(debugger, internal_dict):
    debugger.GetCommandInterpreter().HandleCommand(
        "command script add -f staging_capture_debugger_reader.check healthcomp-capture-check",
        lldb.SBCommandReturnObject(), False)
