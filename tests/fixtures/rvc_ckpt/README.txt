Tiny fakes for tests/test_rvc.py (none is a real voice model):
  not-a-pickle.pth   plain text with a .pth name
  traversal.zip      zip with a '../evil.pth' member
  pickle-trap.pth    torch-shaped zip whose data.pkl calls print() when unpickled (harmless);
                     torch.load(weights_only=True) must refuse it
