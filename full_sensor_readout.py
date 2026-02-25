import glob
import board, adafruit_bh1750, adafruit_tca9548a
import time
from datetime import datetime, timezone
import gspread
from google.oauth2.service_account import Credentials

i2c = board.I2C()
tca = adafruit_tca9548a.TCA9548A(i2c)

# set up channels for light sensor at mux

# set up paths for DHT21
paths = {"sensor1":["/sys/devices/platform/dht11@11/", 4],
"sensor2": ["/sys/devices/platform/dht11@1b/", 3],
"sensor3": ["/sys/devices/platform/dht11@16/", 2],
"sensor4": ["/sys/devices/platform/dht11@a/", 1],
"sensor5": ["/sys/devices/platform/dht11@9/", 0]}

output_data = {}


SPREADSHEET_ID = "1cNXXe7aarhJXx73RJLgEKsWju_jU0Jt5t9QToNSF9GU"   # from the sheet URL
WORKSHEET_NAME = "data"           # tab name
CREDS_JSON_PATH = "/home/admin/Desktop/sepal/sepal-sensors-c5e8e7b74392.json"

SCOPES = ["https://www.googleapis.com/auth/spreadsheets"]
creds = Credentials.from_service_account_file(CREDS_JSON_PATH, scopes=SCOPES)
gc = gspread.authorize(creds)

sh = gc.open_by_key(SPREADSHEET_ID)
ws = sh.worksheet(WORKSHEET_NAME)


ts = datetime.now(timezone.utc).isoformat()

# iterate through sensors
for sensor in paths.keys():
	dht21_devices = glob.glob(f"{paths[sensor][0]}/iio:device*")
	for dev in dht21_devices:
		try: 
			with open(f"{dev}/in_temp_input", "r") as t:
				temp_milli = int(t.read().strip())
			with open(f"{dev}/in_humidityrelative_input", "r") as h:
				hum_milli = int(h.read().strip())
				temp_c = temp_milli / 1000.0
				humidity = hum_milli / 1000.0
				#print(f"Device: {sensor}")
		except TimeoutError:
			continue
	try:
		light_sensor = adafruit_bh1750.BH1750(tca[paths[sensor][1]])
		lux = round(light_sensor.lux, 2)
	except (OSError, ValueError):
		output_data[sensor] = ["NaN", "NaN", "NaN"]
		continue
	# key: [temp, hum, lux]
	output_data[sensor] = [temp_c, humidity, lux]

rows = [[f"temp_{i}", f"humidity_{i} ", f"lux_{i}"] for i in range(1,6)]
rows = ["ts"] + [x for xs in rows for x in xs] #flatten rows

output_list = [ts] + [x for xs in list(output_data.values()) for x in xs]
print(output_list)

if ws.row_values(1) != rows:
	ws.update("A1:P1", [rows])

ws.append_row(output_list, value_input_option="RAW")



      
