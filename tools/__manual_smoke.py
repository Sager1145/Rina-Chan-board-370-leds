
import importlib.util, pathlib, sys, types
ROOT=pathlib.Path(__file__).resolve().parents[1]; PICO=ROOT/'pico_firmware'
mock=types.ModuleType('board'); mock.SRC_ROWS=16; mock.SRC_COLS=18; mock.SRC_INVALID_COLS=(0,17); mock.ROWS=18; mock.COLS=22; mock.ROW_LENGTHS=[18,20,20,20,22,22,22,22,22,22,22,22,22,20,20,20,18,16]
mock.logical_to_led_index=lambda x,y: 0 if 0<=x<22 and 0<=y<18 else None
mock.draw_pixel_grid=lambda *a,**k: None; mock.draw_face_matrix=lambda *a,**k: None; mock.sleep_ms=lambda ms: None
sys.modules['board']=mock; sys.modules['board_370']=mock; sys.path.insert(0,str(PICO))
spec=importlib.util.spec_from_file_location('rina_protocol',PICO/'rina_protocol.py'); rp=importlib.util.module_from_spec(spec); spec.loader.exec_module(rp)
class S: manual_control_mode=False; auto=False
class A:
  def __init__(self): self.state=S()
  def set_manual_control_mode(self,enabled=True,redraw=False,source=''): self.state.manual_control_mode=bool(enabled); return self.state.manual_control_mode
  def manual_control_status_json(self): return '{"manual_control_mode":'+('true' if self.state.manual_control_mode else 'false')+'}'
  def on_network_control(self): self.state.manual_control_mode=False
  def battery_status_json(self): return '{}'
sent=[]; app=A(); p=rp.RinaProtocol(sender=lambda ip,port,data,link_id=0: sent.append(bytes(data)),app=app)
p.handle_packet(b'manualMode|1','ip',1); assert app.state.manual_control_mode and sent[-1]==b'manualMode|1'
p.handle_packet(b'requestManualMode','ip',1); assert b'true' in sent[-1]
p.handle_packet(b'#010203','ip',1); assert not app.state.manual_control_mode
p.handle_packet(b'requestState','ip',1); assert b'"manual_control_mode":false' in sent[-1]
print('manual smoke PASS')
