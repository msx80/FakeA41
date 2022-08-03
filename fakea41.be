#- 

FakeA41

Tasmota enabled DIY Replacement for brp069a41 wifi modules on Daikin A/C units.

Info at: https://github.com/msx80/FakeA41

-#

# Pins for software serial, adjust as needed

GPIO_RX = 6
GPIO_TX = 4


# decoding table for JSON messages

MODE_CODES = {
	'COOL': 0x33,
	'HEAT': 0x34,
	'FAN': 0x36,
	'DRY': 0x32,
	'AUTO': 0x37
}

FAN_CODES = {
	'AUTO': 0x41,
	'NIGHT': 0x42,
	'1': 0x33,
	'2': 0x34,
	'3': 0x35,
	'4': 0x36,
	'5': 0x37
}


import string

#========= Utils

def invertMap(map)
  var res = {}
  for i : map.keys()
	res[map[i]]=i
  end
  return res;
end


MODE_CODES_INV = invertMap(MODE_CODES)
FAN_CODES_INV = invertMap(FAN_CODES)


#========= Checksum Functions

def calcChecksum(buf)
	var sum = 0
	for i : 1..buf.size()-3
		sum = sum + buf[i]
	end
	return sum%256
end

def setChecksum(buf)
	var cs = calcChecksum(buf)
	buf[buf.size()-2] = cs
end

def verifyChecksum(buf)
	var cs = calcChecksum(buf)
	if buf[buf.size()-2] != cs
		raise "io_error", "Invalid checksum"
	end
end


#========= Serial IO utilities

def readWithTimeout(ser, timeoutMillis)
	var start = tasmota.millis()
	while ser.available() == 0
		var now = tasmota.millis()
		if now-start >= timeoutMillis
			return bytes()
		end
	end
	return ser.read()
end


#-

 Read single bytes from serial port with buffer and timeout.
 The standard serial.read() always return the whole buffer, so
 you can't read byte by byte easily. With this class you can.

-#

class SerReader

	var ser 	# serial connection
	var buffer	# buffer with available data
	var timeout	# timeout in millis for reads

	def init(ser, timeout)
		self.ser = ser
		self.timeout = timeout
		self.buffer = bytes()
	end

	def readByte()
       	if self.buffer.size() >= 1
			var res = self.buffer[0]
			self.buffer = self.buffer[1..-1] # perhaps we could keep a cursor to avoid copying the buffer every time
			return res 
		else
			self.buffer = readWithTimeout(self.ser, self.timeout)
			if self.buffer.size() == 0
		    		return nil
			else
				return self.readByte() # tail recurse now that buffer is full
			end
		end
	end

	def readByteOrRaise()
		var b = self.readByte()
		if b == nil
			raise "io_error", "Timeout reading from serial"
		end
		return b
	end

	def available()
		# the total amount of bytes available are those in the local buffer
		# plus those in the serial buffer
		return self.buffer.size() + self.ser.available()
	end
	
	def cleanBuffers()
		self.buffer = bytes()
		self.ser.read()
	end

	def write(data)
		self.ser.write(data)
	end
end



#========= S21 Protocol stuff


# read a single byte and check it's 06 (ACK)
def readAck(reader)
	var head = reader.readByteOrRaise()
	if head != 6
		raise "io_error", "Invalid ack"
	end
end

# read a packet from 02 (STX) to 03 (ETX)
def readRawPacket(reader)
	var buffer = bytes()
	var head = reader.readByteOrRaise()
	if head != 2
		raise "io_error", "Bad start of pkt"
	end
	buffer..head
	while true
		var b = reader.readByteOrRaise()
		buffer..b
		if b == 3 
			return buffer
		else
			if buffer.size()>100
				raise "io_error", "Message too long"
			end
		end
	end
end


# read a complete reply: ack + packet and check the checksum
# return the packet 
def readReply(reader)
	readAck(reader)
	var pkt = readRawPacket(reader)
	verifyChecksum(pkt)
	log("Daiking Receiving "+pkt.tohex())
	return pkt
end

def writePacket(reader, pkt)
	# before sending a packet we discard the input buffer
	# to get rid of any unexpected input from the device.
	# this way in the event of a desincronization 
	# we can reestablish communication
	reader.cleanBuffers()

	setChecksum(pkt)
	log("Daiking Sending "+pkt.tohex())
	reader.write(pkt)
end

# Extract the temperature from a temperature-reporting package
def extractTemperature(pkt)
	# es 025361 3035302B 7403
	# es 025348 3030322B 5803
	var str = pkt[3..6].asstring()
	var res = str[2]+str[1]+"."+str[0]
	# only add sign if it's minus, json number can't start with +
	if str[3] != '+'
		res = str[3]+res
	end
	return res
end

def readOutsideTemperature(reader)
	writePacket(reader, bytes("025261b303"))
	var pkt = readReply(reader)
	return extractTemperature(pkt)
end

def readInsideTemperature(reader)
	writePacket(reader, bytes("0252489a03"))
	var pkt = readReply(reader)
	return extractTemperature(pkt)
end

def readUnitState(reader)
	writePacket(reader, bytes("0246317703"))
	var pkt = readReply(reader)
	
	var active = pkt[3] == 0x31 ? true : false
	var mode = MODE_CODES_INV[pkt[4]]
	var temperature = (pkt[5]-28)/2
	var fan = FAN_CODES_INV[pkt[6]]	
	
	return "\"active\":"+str(active)+
			",\"mode\":\""+mode+"\"" +
			",\"temperature\":"+str(temperature) +
			",\"fan\":\""+fan+"\""
	
end

def writeSwings(reader, swingV, swingH)
	var cmd = bytes("024435FFFF30800003")
	if swingV && swingH
		cmd[3] = 0x37
	elif swingV
		cmd[3] = 0x31
	elif swingH
		cmd[3] = 0x32
	else
		cmd[3] = 0x30
	end

	cmd[4] = (cmd[3] == 0x30) ? 0x30 : 0x37
	writePacket(reader, cmd)
	readAck(reader)
end

def writeCommand(reader, active, mode, temperature, fan)
	var cmd = bytes("024431FFFFFFFF0003")

	cmd[3] = active ? 0x31 : 0x30
	cmd[4] = MODE_CODES[mode]
	cmd[5] = temperature * 2 + 28
	cmd[6] = FAN_CODES[fan]

	writePacket(reader, cmd)
	readAck(reader)
end



#========= Main driver class

class FakeA41 : Driver

	var reader

	def init()
		var ser = serial(GPIO_RX, GPIO_TX, 2400, serial.SERIAL_8E2)
		self.reader = SerReader(ser, 1000)
	end

	# called by driver infrastructure
	def json_append() 
		var msg = 
			",\"OutsideTemperature\":"+readOutsideTemperature(self.reader)+
			",\"InsideTemperature\":"+readInsideTemperature(self.reader)+
			","+readUnitState(self.reader)
		tasmota.response_append(msg)
	end

	# called by driver infrastructure
	def web_sensor()
		var msg = 
			"{s}Outside Temperature{m}"+readOutsideTemperature(self.reader)+" °C{e}"+
			"{s}Inside Temperature{m}"+readInsideTemperature(self.reader)+" °C{e}"
		tasmota.web_send_decimal(msg)
	end

	# send a command to the unit.
	# es: DaikinCtrl {"active":false, "mode":"COOL", "fan":"NIGHT", "temperature":20, "swingH":false, "swingV":false }
	def cmdControl(cmdx, idx, payload, j)
		
		try
			if j == nil
				raise "type_error", "request is not valid json"
			end
			var active = j['active']
			var mode = j['mode']  # "FAN", "COOL", "DRY", "HEAT"
			var fan = j['fan']    # "1", "2", "3", "4", "Auto", "Night"
			var temperature = j['temperature']
			var swingV = j['swingV']
			var swingH = j['swingH']

			# first set the swings so if anything goes bad the state is unchanged
			# only send if turning on, no need to set if powering down
			if active 
				writeSwings(self.reader, swingV, swingH)
			end

			# write the actual command
			writeCommand(self.reader, active, mode, temperature, fan)

			tasmota.resp_cmnd_done()
			
			tasmota.set_timer(100, / -> tasmota.cmd('TelePeriod')) # run teleperiod to update the state to home automation
		except .. as e, v
			log("Error in Daikin cmd: "+str(e) + ' ' + str(v))
			tasmota.resp_cmnd_str("ERR: "+str(e) + ' ' + str(v))
		end
	end
end


var fakeA41Driver = FakeA41()
tasmota.add_driver(fakeA41Driver)
tasmota.add_cmd("DaikinCtrl", / cmd idx payload payload_json -> fakeA41Driver.cmdControl(cmd, idx, payload, payload_json) )

log("Daikin controller installed")
