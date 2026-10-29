#!/usr/bin/env python3
"""Offline bounded native-output interchange checks; no weights/inference."""
import base64,importlib.util,pathlib,struct,tempfile,unittest
ROOT=pathlib.Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('pii_native_export',ROOT/'scripts/export-pii-native-eval.py');module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)

class NativeOutput(unittest.TestCase):
    def setUp(self):
        self.folder=tempfile.TemporaryDirectory();self.addCleanup(self.folder.cleanup);self.path=pathlib.Path(self.folder.name)/'actual.bin'
        self.values=struct.pack('<'+'f'*36,*([0.0]*36));self.rows=[{'shape':[1,1,12,3],'logitsBase64':base64.b64encode(self.values).decode()} for _ in range(3)]
        tensor=struct.pack('<IQQQQQ',4,1,1,12,3,36)+self.values
        self.data=b'OSWPOUT1'+struct.pack('<I',3)+tensor*3
    def parse(self,data):self.path.write_bytes(data);return module.output_tensors(self.path,self.rows)
    def test_complete_exact_tensors_accepted(self):
        result=self.parse(self.data);self.assertEqual(result,[(self.values,0)]*3)
    def test_header_rank_shape_count_truncation_and_trailing_bytes_refuse(self):
        for offset,value in [(0,b'BROKEN!!'),(8,struct.pack('<I',2)),(12,struct.pack('<I',3)),(16,struct.pack('<Q',2)),(48,struct.pack('<Q',37))]:
            data=self.data[:offset]+value+self.data[offset+len(value):]
            with self.subTest(offset=offset),self.assertRaises(ValueError):self.parse(data)
        for data in [self.data[:7],self.data[:-1],self.data+b'extra']:
            with self.assertRaises(ValueError):self.parse(data)
    def test_nonfinite_actual_and_reference_tensors_refuse(self):
        for value in [float('nan'),float('inf'),-float('inf')]:
            data=self.data[:56]+struct.pack('<f',value)+self.data[60:]
            with self.assertRaises(ValueError):self.parse(data)
            self.rows[0]['logitsBase64']=base64.b64encode(struct.pack('<f',value)+self.values[4:]).decode()
            with self.assertRaises(ValueError):self.parse(self.data)
            self.rows[0]['logitsBase64']=base64.b64encode(self.values).decode()
    def test_reference_size_and_numeric_tolerance_refuse_changed_data(self):
        self.rows[0]['logitsBase64']=base64.b64encode(self.values[:-4]).decode()
        with self.assertRaises(ValueError):self.parse(self.data)
        self.rows[0]['logitsBase64']=base64.b64encode(self.values).decode()
        changed=self.data[:56]+struct.pack('<f',0.1)+self.data[60:]
        with self.assertRaises(ValueError):self.parse(changed)

if __name__=='__main__':unittest.main()
