import serial, time                                                                                                                                                                                           
s = serial.Serial('/dev/cu.usbserial-1101', 115200, timeout=2)                                                                                                                                                
print('Port open')                                                                                                                                                                                            
data = s.read(500)
print('Port 1101 got %d bytes: %r' % (len(data), data[:100]))                                                                                                                                                 
s.close()                                                 
              