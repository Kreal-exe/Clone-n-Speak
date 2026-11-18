import os
import sys


def run(action, inputs, ctx):
    if action == "make":
        ctx.status("Working")
        ctx.progress(0.5)
        ctx.log("half way")
        with open(os.path.join(ctx.work_dir, "out.txt"), "w") as f:
            f.write(str(inputs.get("text", "")))
        return {"outputs": ["out.txt"], "text": "done"}
    if action == "escape_rel":
        return {"outputs": ["../x"]}
    if action == "escape_abs":
        return {"outputs": ["/etc/hosts"]}
    if action == "chatty":
        print("this is plain print output")
        sys.stdout.write("and more\n")
        os.write(1, b"raw fd write\n")
        return {"outputs": []}
    if action == "crash":
        raise RuntimeError("boom")
    return {}
