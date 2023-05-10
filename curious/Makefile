DB=enceladus

BUILD=${CURDIR}/build.sql
SCRIPTS=${CURDIR}/scripts

CSV='${CURDIR}/data/master_plan.csv'
INMS_CSV='${CURDIR}/data/inms.csv'
CDA_CSV='${CURDIR}/data/cda.csv'
JPL_FLYBYS_CSV='${CURDIR}/data/jpl_flybys.csv'
CHEM_DATA_CSV='${CURDIR}/data/chem_data.csv'

CREATE_MASTER_PLAN_TABLE=$(SCRIPTS)/create_table_master_plan.sql

all: import normalize
	psql -U postgres -d $(DB) -f $(BUILD)

normalize:
	@echo "normalizing db"
	psql -U postgres -d $(DB) -f $(BUILD)

import:
	@echo "importing master_plan"
	@cat $(CREATE_MASTER_PLAN_TABLE) >> $(BUILD)
	@echo "COPY import.master_plan FROM $(CSV) WITH DELIMITER ',' HEADER CSV;" >> $(BUILD)
	psql -U postgres -d $(DB) -f $(BUILD)
	
foo:
	echo "no @s"
	head $(BUILD)

bar:
	@echo "yes @"
	@head $(BUILD)

clean:
	@rm -rf $(BUILD)
