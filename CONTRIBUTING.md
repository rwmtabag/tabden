# Contributing

Thanks for helping. A few things before you start:

- **Read [docs/design.md](docs/design.md) first.** It explains how the scripts fit together and the rules they follow.
- **Run the checks before a pull request.** CI runs the same ones:

  ```bash
  for f in launcher.sh guest.sh tools/record-demo.sh; do bash -n "$f"; done
  shellcheck -S warning launcher.sh guest.sh tools/record-demo.sh
  ```

- **Bug reports:** include the output of `tabden doctor`. It leaves out your username, git identity and timezone, but read it once before posting.
- **Test on a real device.** Changes need a run on an actual Android device with Termux, not only an emulator or a desktop; say in the pull request which device and Android version you used.
