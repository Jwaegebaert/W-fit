using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace WFit.Api.Data.Migrations
{
    /// <inheritdoc />
    public partial class NumberedStacks : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.AddColumn<double>(
                name: "Plate",
                table: "SetLogs",
                type: "float",
                nullable: true);

            migrationBuilder.AddColumn<string>(
                name: "StackPlatesJson",
                table: "Profiles",
                type: "nvarchar(2000)",
                maxLength: 2000,
                nullable: false,
                defaultValue: "{}");
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropColumn(
                name: "Plate",
                table: "SetLogs");

            migrationBuilder.DropColumn(
                name: "StackPlatesJson",
                table: "Profiles");
        }
    }
}
